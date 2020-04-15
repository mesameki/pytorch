#include <torch/extension.h>
#include <c10/cuda/CUDAStream.h>
#include <ATen/Generator.h>
#include <ATen/Tensor.h>
#include <ATen/native/DistributionTemplates.h>
#include <ATen/core/op_registration/op_registration.h>
#include <ATen/cuda/Exceptions.h>
#include <ATen/core/DistributionsHelper.h>
#include <memory>
#include "aes.cuh"
#include "block_cipher.cuh"

using namespace at;

struct CUDA_CSPRNG_GeneratorImpl : public CPUGeneratorImpl {
  CUDA_CSPRNG_GeneratorImpl(uint64_t seed_in = default_rng_seed_val) : CPUGeneratorImpl(seed_in) {
    this->key_set_ = DispatchKeySet(DispatchKey::CustomRNGKeyId);
  }
};

// ===========================================================================================================================

template<typename scalar_t, typename uint_t, size_t N = 1, typename transform_t>
void block_cipher_helper(TensorIterator& iter, uint8_t* key, transform_t transform_func) {
  block_cipher_ctr_mode<scalar_t, uint_t, N>(iter,
    [key] __device__ (unsigned int idx) -> block_t {
      block_t block;
      memset(&block, 0, block_t_size);
      *(reinterpret_cast<unsigned int*>(&block)) = idx;
      encrypt(reinterpret_cast<uint8_t*>(&block), key);
      return block;
    },
    transform_func
  );
}

// ===========================================================================================================================

template<typename scalar_t, typename uint_t>
void random_kernel_helper_fp(TensorIterator& iter, uint8_t* key) {
  block_cipher_helper<scalar_t, uint_t>(iter, key,
    [] __device__ (DummyRNG<1>* generator) -> scalar_t {
      if (std::is_same<scalar_t, double>::value) {
        return static_cast<scalar_t>(generator->random64() % static_cast<uint64_t>((1ULL << std::numeric_limits<scalar_t>::digits) + 1));
      } else {
        return static_cast<scalar_t>(generator->random() % static_cast<uint64_t>((1ULL << std::numeric_limits<scalar_t>::digits) + 1));
      }
    }
  );
}

template<typename scalar_t, typename uint_t>
void random_kernel_helper_int(TensorIterator& iter, uint8_t* key) {
  block_cipher_helper<scalar_t, uint_t>(iter, key,
    [] __device__ (DummyRNG<1>* generator) -> scalar_t {
      if (std::is_same<scalar_t, long>::value) {
        return static_cast<scalar_t>(generator->random64() % (static_cast<uint64_t>(std::numeric_limits<scalar_t>::max()) + 1));
      } else {
        return static_cast<scalar_t>(generator->random() % (static_cast<uint64_t>(std::numeric_limits<scalar_t>::max()) + 1));
      }
    }
  );
}

void random_kernel_helper_bool(TensorIterator& iter, uint8_t* key) {
  block_cipher_helper<bool, uint32_t>(iter, key,
    [] __device__ (DummyRNG<1>* generator) -> bool {
      return static_cast<bool>(generator->random() & 1);
    }
  );
}

template<typename RNG>
struct RandomKernel {
  void operator()(TensorIterator& iter, c10::optional<Generator> generator) {
    const auto key_t = key_tensor(generator);
    const auto key = key_t.data_ptr<uint8_t>();
    if (isFloatingType(iter.dtype())) {
      AT_DISPATCH_FLOATING_TYPES(iter.dtype(), "random_kernel_fp_cuda", [&] {
        if (std::is_same<scalar_t, double>::value) {
          random_kernel_helper_fp<scalar_t, uint64_t>(iter, key);
        } else {
          random_kernel_helper_fp<scalar_t, uint32_t>(iter, key);
        }
      });
    } else if (isIntegralType(iter.dtype(), /*includeBool=*/true)) {
      AT_DISPATCH_INTEGRAL_TYPES_AND(ScalarType::Bool, iter.dtype(), "random_kernel_int_cuda", [&] {
        if (std::is_same<scalar_t, int64_t>::value) {
          random_kernel_helper_int<scalar_t, uint64_t>(iter, key);
        } else if (std::is_same<scalar_t, bool>::value) {
          random_kernel_helper_bool(iter, key);
        } else {
          random_kernel_helper_int<scalar_t, uint32_t>(iter, key);
        }
      });
    }
  }
};

Tensor& random_(Tensor& self, c10::optional<Generator> generator) {
  return native::templates::random_impl<RandomKernel, CUDA_CSPRNG_GeneratorImpl>(self, generator);
}

// ===========================================================================================================================

template<typename scalar_t, typename uint_t>
void uniform_kernel_helper_fp(TensorIterator& iter, uint8_t* key, scalar_t from, scalar_t to) {
  block_cipher_helper<scalar_t, uint_t>(iter, key,
    [from, to] __device__ (DummyRNG<1>* generator) -> scalar_t {
      uniform_real_distribution<scalar_t> uniform(from, to);
      return uniform(generator);
    }
  );
}

template<typename RNG>
struct UniformKernel {
  void operator()(TensorIterator& iter, double from, double to, c10::optional<Generator> generator) {
    const auto key_t = key_tensor(generator);
    const auto key = key_t.data_ptr<uint8_t>();
    AT_DISPATCH_FLOATING_TYPES(iter.dtype(), "uniform_kernel_cuda", [&] {
      if (std::is_same<scalar_t, double>::value) {
        uniform_kernel_helper_fp<scalar_t, uint64_t>(iter, key, from, to);
      } else {
        uniform_kernel_helper_fp<scalar_t, uint32_t>(iter, key, from, to);
      }
    });
  }
};

Tensor& uniform_(Tensor& self, double from, double to, c10::optional<Generator> generator) {
  return native::templates::uniform_impl_<UniformKernel, CUDA_CSPRNG_GeneratorImpl>(self, from, to, generator);
}

// ===========================================================================================================================

template<typename scalar_t, typename uint_t>
void normal_kernel_helper_fp(TensorIterator& iter, scalar_t mean, scalar_t std, uint8_t* key) {
  block_cipher_helper<scalar_t, uint_t, 2>(iter, key,
    [mean, std] __device__ (DummyRNG<2>* generator) -> scalar_t {
      normal_distribution<scalar_t> normal(mean, std);
      return normal(generator);
    }
  );
}

template<typename RNG>
struct NormalKernel {
  void operator()(Tensor& self, double mean, double std, c10::optional<Generator> generator) {
    const auto key_t = key_tensor(generator);
    const auto key = key_t.data_ptr<uint8_t>();
    auto iter = TensorIterator::nullary_op(self);
    AT_DISPATCH_FLOATING_TYPES(iter.dtype(), "normal_kernel_cuda", [&] {
      if (std::is_same<scalar_t, double>::value) {
        normal_kernel_helper_fp<scalar_t, uint64_t>(iter, mean, std, key);
      } else {
        normal_kernel_helper_fp<scalar_t, uint32_t>(iter, mean, std, key);
      }
    });
  }
};

Tensor& normal_(Tensor& self, double mean, double std, c10::optional<Generator> generator) {
  return native::templates::normal_impl_<NormalKernel, CUDA_CSPRNG_GeneratorImpl>(self, mean, std, generator);
}

Tensor& normal_Tensor_float_out(Tensor& output, const Tensor& mean, double std, c10::optional<Generator> gen) {
  return native::templates::normal_out_impl<NormalKernel, CUDA_CSPRNG_GeneratorImpl>(output, mean, std, gen);
}

Tensor& normal_float_Tensor_out(Tensor& output, double mean, const Tensor& std, c10::optional<Generator> gen) {
  return native::templates::normal_out_impl<NormalKernel, CUDA_CSPRNG_GeneratorImpl>(output, mean, std, gen);
}

Tensor& normal_Tensor_Tensor_out(Tensor& output, const Tensor& mean, const Tensor& std, c10::optional<Generator> gen) {
  return native::templates::normal_out_impl<NormalKernel, CUDA_CSPRNG_GeneratorImpl>(output, mean, std, gen);
}

Tensor normal_Tensor_float(const Tensor& mean, double std, c10::optional<Generator> gen) {
  return native::templates::normal_impl<NormalKernel, CUDA_CSPRNG_GeneratorImpl>(mean, std, gen);
}

Tensor normal_float_Tensor(double mean, const Tensor& std, c10::optional<Generator> gen) {
  return native::templates::normal_impl<NormalKernel, CUDA_CSPRNG_GeneratorImpl>(mean, std, gen);
}

Tensor normal_Tensor_Tensor(const Tensor& mean, const Tensor& std, c10::optional<Generator> gen) {
  return native::templates::normal_impl<NormalKernel, CUDA_CSPRNG_GeneratorImpl>(mean, std, gen);
}

// ===========================================================================================================================

Generator create_CUDA_CSPRNG_Generator() {
  return make_generator<CUDA_CSPRNG_GeneratorImpl>();
}
  
void registerOps() {
  static auto registry = torch::import()
    // Random
    .impl_UNBOXED("aten::random_", DispatchKey::CustomRNGKeyId, random_)
    // Uniform
    .impl_UNBOXED("aten::uniform_", DispatchKey::CustomRNGKeyId, uniform_)
    // Normal
    .impl_UNBOXED("aten::normal_",                  DispatchKey::CustomRNGKeyId, normal_)
    .impl_UNBOXED("aten::normal.Tensor_float_out",  DispatchKey::CustomRNGKeyId, normal_Tensor_float_out)
    .impl_UNBOXED("aten::normal.float_Tensor_out",  DispatchKey::CustomRNGKeyId, normal_float_Tensor_out)
    .impl_UNBOXED("aten::normal.Tensor_Tensor_out", DispatchKey::CustomRNGKeyId, normal_Tensor_Tensor_out)
    .impl_UNBOXED("aten::normal.Tensor_float",      DispatchKey::CustomRNGKeyId, normal_Tensor_float)
    .impl_UNBOXED("aten::normal.float_Tensor",      DispatchKey::CustomRNGKeyId, normal_float_Tensor)
    .impl_UNBOXED("aten::normal.Tensor_Tensor",     DispatchKey::CustomRNGKeyId, normal_Tensor_Tensor)
  ;
}

PYBIND11_MODULE(TORCH_EXTENSION_NAME, m) {
  m.def("registerOps", &registerOps);
  m.def("create_CUDA_CSPRNG_Generator", &create_CUDA_CSPRNG_Generator);
}
