/*
 * Copyright (c) 2022 NVIDIA Corporation
 *
 * Licensed under the Apache License Version 2.0 with LLVM Exceptions
 * (the "License"); you may not use this file except in compliance with
 * the License. You may obtain a copy of the License at
 *
 *   https://llvm.org/LICENSE.txt
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
#pragma once

#if defined(USE_GPU)

#include <stdexec/__detail/__config.hpp>
#include <map>
#include <chrono>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <charconv>
#include <string_view>
#include <memory>
#include <vector>
#include <string.h>

#include <math.h>

#if defined(_NVHPC_CUDA) || defined(__CUDACC__)
#define STDEXEC_STDERR
#include <nvexec/detail/throw_on_cuda_error.cuh>
#endif

#include <stdexec/execution.hpp>
#include <exec/on.hpp>


#if defined(_NVHPC_CUDA) || defined(__CUDACC__)
#include <nvexec/detail/throw_on_cuda_error.cuh>
#include <nvexec/stream_context.cuh>
#include <nvexec/multi_gpu_context.cuh>
#else
namespace nvexec {
  struct stream_receiver_base {
    using receiver_concept = stdexec::receiver_t;
  };

  struct stream_sender_base {
    using sender_concept = stdexec::sender_t;
  };
  namespace detail {
    struct stream_op_state_base { };
  }

  inline bool is_on_gpu() {
    return false;
  }
}
#endif

#include <optional>
#include <exec/inline_scheduler.hpp>
#include <exec/static_thread_pool.hpp>

namespace ex = stdexec;

#if defined(_NVHPC_CUDA) || defined(__CUDACC__)
namespace nvexec::STDEXEC_STREAM_DETAIL_NS { //

  namespace repeat_n {
    template <class OpT>
    class receiver_2_t : public stream_receiver_base {
      using Sender = typename OpT::PredSender;
      using Receiver = typename OpT::Receiver;

      OpT& op_state_;

     public:
      template <stdexec::__one_of<ex::set_error_t, ex::set_stopped_t> _Tag, class... _Args>
      friend void tag_invoke(_Tag __tag, receiver_2_t&& __self, _Args&&... __args) noexcept {
        OpT& op_state = __self.op_state_;
        op_state.propagate_completion_signal(_Tag{}, (_Args&&) __args...);
      }

      friend void tag_invoke(ex::set_value_t, receiver_2_t&& __self) noexcept {
        using inner_op_state_t = typename OpT::inner_op_state_t;

        OpT& op_state = __self.op_state_;
        op_state.i_++;

        if (op_state.i_ == op_state.n_) {
          op_state.propagate_completion_signal(stdexec::set_value);
          return;
        }

        auto sch = stdexec::get_scheduler(stdexec::get_env(op_state.rcvr_));
        inner_op_state_t& inner_op_state = op_state.inner_op_state_.emplace(
          stdexec::__conv{[&]() noexcept {
            return ex::connect(ex::schedule(sch) | op_state.closure_, receiver_2_t<OpT>{op_state});
          }});

        ex::start(inner_op_state);
      }

      friend typename OpT::env_t tag_invoke(ex::get_env_t, const receiver_2_t& self) noexcept {
        return self.op_state_.make_env();
      }

      explicit receiver_2_t(OpT& op_state)
        : op_state_(op_state) {
      }
    };

    template <class OpT>
    class receiver_1_t : public stream_receiver_base {
      using Receiver = typename OpT::Receiver;

      OpT& op_state_;

     public:
      template <stdexec::__one_of<ex::set_error_t, ex::set_stopped_t> _Tag, class... _Args>
      friend void tag_invoke(_Tag __tag, receiver_1_t&& __self, _Args&&... __args) noexcept {
        OpT& op_state = __self.op_state_;
        op_state.propagate_completion_signal(_Tag{}, (_Args&&) __args...);
      }

      friend void tag_invoke(ex::set_value_t, receiver_1_t&& __self) noexcept {
        using inner_op_state_t = typename OpT::inner_op_state_t;

        OpT& op_state = __self.op_state_;

        if (op_state.n_) {
          auto sch = stdexec::get_scheduler(stdexec::get_env(op_state.rcvr_));
          inner_op_state_t& inner_op_state = op_state.inner_op_state_.emplace(
            stdexec::__conv{[&]() noexcept {
              return ex::connect(
                ex::schedule(sch) | op_state.closure_, receiver_2_t<OpT>{op_state});
            }});

          ex::start(inner_op_state);
        } else {
          op_state.propagate_completion_signal(stdexec::set_value);
        }
      }

      friend typename OpT::env_t tag_invoke(ex::get_env_t, const receiver_1_t& self) noexcept {
        return self.op_state_.make_env();
      }

      explicit receiver_1_t(OpT& op_state)
        : op_state_(op_state) {
      }
    };

    template <class PredecessorSenderId, class Closure, class ReceiverId>
    struct operation_state_t : operation_state_base_t<ReceiverId> {
      using PredSender = stdexec::__t<PredecessorSenderId>;
      using Receiver = stdexec::__t<ReceiverId>;
      using Scheduler =
        stdexec::tag_invoke_result_t<stdexec::get_scheduler_t, stdexec::env_of_t<Receiver>>;
      using InnerSender =
        std::invoke_result_t<Closure, stdexec::tag_invoke_result_t<stdexec::schedule_t, Scheduler>>;

      using predecessor_op_state_t =
        ex::connect_result_t<PredSender, receiver_1_t<operation_state_t>>;
      using inner_op_state_t = ex::connect_result_t<InnerSender, receiver_2_t<operation_state_t>>;

      PredSender pred_sender_;
      Closure closure_;
      std::optional<predecessor_op_state_t> pred_op_state_;
      std::optional<inner_op_state_t> inner_op_state_;
      std::size_t n_{};
      std::size_t i_{};

      friend void tag_invoke(stdexec::start_t, operation_state_t& op) noexcept {
        if (op.stream_provider_.status_ != cudaSuccess) {
          // Couldn't allocate memory for operation state, complete with error
          op.propagate_completion_signal(
            stdexec::set_error, std::move(op.stream_provider_.status_));
        } else {
          if (op.n_) {
            stdexec::start(*op.pred_op_state_);
          } else {
            op.propagate_completion_signal(stdexec::set_value);
          }
        }
      }

      operation_state_t(PredSender&& pred_sender, Closure closure, Receiver&& rcvr, std::size_t n)
        : operation_state_base_t<ReceiverId>(
          (Receiver&&) rcvr,
          stdexec::get_completion_scheduler<stdexec::set_value_t>(stdexec::get_env(pred_sender))
            .context_state_)
        , pred_sender_{(PredSender&&) pred_sender}
        , closure_(closure)
        , n_(n) {
        pred_op_state_.emplace(stdexec::__conv{[&]() noexcept {
          return ex::connect((PredSender&&) pred_sender_, receiver_1_t{*this});
        }});
      }
    };
}}
#endif

namespace repeat_n_detail {

  template <class OpT>
  class receiver_2_t {
    using Sender = typename OpT::PredSender;
    using Receiver = typename OpT::Receiver;

    OpT& op_state_;

   public:
    using receiver_concept = stdexec::receiver_t;

    template <stdexec::__one_of<ex::set_error_t, ex::set_stopped_t> _Tag, class... _Args>
    friend void tag_invoke(_Tag __tag, receiver_2_t&& __self, _Args&&... __args) noexcept {
      OpT& op_state = __self.op_state_;
      __tag(std::move(op_state.rcvr_), (_Args&&) __args...);
    }

    friend void tag_invoke(ex::set_value_t, receiver_2_t&& __self) noexcept {
      using inner_op_state_t = typename OpT::inner_op_state_t;

      OpT& op_state = __self.op_state_;
      op_state.i_++;

      if (op_state.i_ == op_state.n_) {
        stdexec::set_value(std::move(op_state.rcvr_));
        return;
      }

      auto sch = stdexec::get_scheduler(stdexec::get_env(op_state.rcvr_));
      inner_op_state_t& inner_op_state = op_state.inner_op_state_.emplace(
        stdexec::__conv{[&]() noexcept {
          return ex::connect(ex::schedule(sch) | op_state.closure_, receiver_2_t<OpT>{op_state});
        }});

      ex::start(inner_op_state);
    }

    friend auto tag_invoke(ex::get_env_t, const receiver_2_t& self) noexcept
      -> stdexec::env_of_t<Receiver> {
      return stdexec::get_env(self.op_state_.rcvr_);
    }

    explicit receiver_2_t(OpT& op_state)
      : op_state_(op_state) {
    }
  };

  template <class OpT>
  class receiver_1_t {
    using Receiver = typename OpT::Receiver;

    OpT& op_state_;

   public:
    using receiver_concept = stdexec::receiver_t;

    template <stdexec::__one_of<ex::set_error_t, ex::set_stopped_t> _Tag, class... _Args>
    friend void tag_invoke(_Tag __tag, receiver_1_t&& __self, _Args&&... __args) noexcept {
      OpT& op_state = __self.op_state_;
      __tag(std::move(op_state.rcvr_), (_Args&&) __args...);
    }

    friend void tag_invoke(ex::set_value_t, receiver_1_t&& __self) noexcept {
      using inner_op_state_t = typename OpT::inner_op_state_t;

      OpT& op_state = __self.op_state_;

      if (op_state.n_) {
        auto sch = stdexec::get_scheduler(stdexec::get_env(op_state.rcvr_));
        inner_op_state_t& inner_op_state = op_state.inner_op_state_.emplace(
          stdexec::__conv{[&]() noexcept {
            return ex::connect(ex::schedule(sch) | op_state.closure_, receiver_2_t<OpT>{op_state});
          }});

        ex::start(inner_op_state);
      } else {
        stdexec::set_value(std::move(op_state.rcvr_));
      }
    }

    friend auto tag_invoke(ex::get_env_t, const receiver_1_t& self) noexcept
      -> stdexec::env_of_t<Receiver> {
      return stdexec::get_env(self.op_state_.rcvr_);
    }

    explicit receiver_1_t(OpT& op_state)
      : op_state_(op_state) {
    }
  };

  template <class PredecessorSenderId, class Closure, class ReceiverId>
  struct operation_state_t {
    using PredSender = stdexec::__t<PredecessorSenderId>;
    using Receiver = stdexec::__t<ReceiverId>;
    using Scheduler =
      stdexec::tag_invoke_result_t<stdexec::get_scheduler_t, stdexec::env_of_t<Receiver>>;
    using InnerSender =
      std::invoke_result_t<Closure, stdexec::tag_invoke_result_t<stdexec::schedule_t, Scheduler>>;

    using predecessor_op_state_t =
      ex::connect_result_t<PredSender, receiver_1_t<operation_state_t>>;
    using inner_op_state_t = ex::connect_result_t<InnerSender, receiver_2_t<operation_state_t>>;

    PredSender pred_sender_;
    Closure closure_;
    Receiver rcvr_;
    std::optional<predecessor_op_state_t> pred_op_state_;
    std::optional<inner_op_state_t> inner_op_state_;
    std::size_t n_{};
    std::size_t i_{};

    friend void tag_invoke(stdexec::start_t, operation_state_t& op) noexcept {
      if (op.n_) {
        stdexec::start(*op.pred_op_state_);
      } else {
        stdexec::set_value(std::move(op.rcvr_));
      }
    }

    operation_state_t(PredSender&& pred_sender, Closure closure, Receiver&& rcvr, std::size_t n)
      : pred_sender_{(PredSender&&) pred_sender}
      , closure_(closure)
      , rcvr_(rcvr)
      , n_(n) {
      pred_op_state_.emplace(stdexec::__conv{[&]() noexcept {
        return ex::connect((PredSender&&) pred_sender_, receiver_1_t{*this});
      }});
    }
  };

  template <class SenderId, class Closure>
  struct repeat_n_sender_t {
    using __t = repeat_n_sender_t;
    using __id = repeat_n_sender_t;
    using Sender = stdexec::__t<SenderId>;
    using sender_concept = stdexec::sender_t;

    using completion_signatures = //
      stdexec::completion_signatures<
        stdexec::set_value_t(),
        stdexec::set_stopped_t(),
        stdexec::set_error_t(std::exception_ptr)
#if defined(_NVHPC_CUDA) || defined(__CUDACC__)
          ,
        stdexec::set_error_t(cudaError_t)
#endif
        >;

    Sender sender_;
    Closure closure_;
    std::size_t n_{};

#if defined(_NVHPC_CUDA) || defined(__CUDACC__)
    template <stdexec::__decays_to<repeat_n_sender_t> Self, stdexec::receiver Receiver>
      requires(stdexec::sender_to<Sender, Receiver>)
           && (!nvexec::STDEXEC_STREAM_DETAIL_NS::receiver_with_stream_env<Receiver>)
    friend auto tag_invoke(stdexec::connect_t, Self&& self, Receiver r)
      -> repeat_n_detail::operation_state_t<SenderId, Closure, stdexec::__id<Receiver>> {
      return repeat_n_detail::operation_state_t<SenderId, Closure, stdexec::__id<Receiver>>(
        (Sender&&) self.sender_, self.closure_, (Receiver&&) r, self.n_);
    }

    template <stdexec::__decays_to<repeat_n_sender_t> Self, stdexec::receiver Receiver>
      requires(stdexec::sender_to<Sender, Receiver>)
           && (nvexec::STDEXEC_STREAM_DETAIL_NS::receiver_with_stream_env<Receiver>)
    friend auto tag_invoke(stdexec::connect_t, Self&& self, Receiver r)
      -> nvexec::STDEXEC_STREAM_DETAIL_NS::repeat_n::
        operation_state_t<SenderId, Closure, stdexec::__id<Receiver>> {
      return nvexec::STDEXEC_STREAM_DETAIL_NS::repeat_n::
        operation_state_t<SenderId, Closure, stdexec::__id<Receiver>>(
          (Sender&&) self.sender_, self.closure_, (Receiver&&) r, self.n_);
    }
#else
    template <stdexec::__decays_to<repeat_n_sender_t> Self, stdexec::receiver Receiver>
      requires stdexec::sender_to<Sender, Receiver>
    friend auto tag_invoke(stdexec::connect_t, Self&& self, Receiver r)
      -> repeat_n_detail::operation_state_t<SenderId, Closure, stdexec::__id<Receiver>> {
      return repeat_n_detail::operation_state_t<SenderId, Closure, stdexec::__id<Receiver>>(
        (Sender&&) self.sender_, self.closure_, (Receiver&&) r, self.n_);
    }
#endif

    friend auto tag_invoke(stdexec::get_env_t, const repeat_n_sender_t& s) //
      noexcept(stdexec::__nothrow_callable<stdexec::get_env_t, const Sender&>)
        -> stdexec::env_of_t<const Sender&> {
      return stdexec::get_env(s.sender_);
    }
  };
}

struct repeat_n_t {
  template <stdexec::sender Sender, stdexec::__sender_adaptor_closure Closure>
  auto operator()(Sender&& __sndr, std::size_t n, Closure closure) const noexcept
    -> repeat_n_detail::repeat_n_sender_t<stdexec::__id<Sender>, Closure> {
    return repeat_n_detail::repeat_n_sender_t<stdexec::__id<Sender>, Closure>{
      std::forward<Sender>(__sndr), closure, n};
  }

  template <stdexec::__sender_adaptor_closure Closure>
  auto operator()(std::size_t n, Closure closure) const
    -> stdexec::__binder_back<repeat_n_t, std::size_t, Closure> {
    return {
      {},
      {},
      {n, (Closure&&) closure}
    };
  }
};

inline constexpr repeat_n_t repeat_n{};

#endif // USE_GPU