#pragma once
#include <string>
#include <utility>

namespace airmuse {
template<class T> class Result {
public:
    static Result Ok(T value) { return Result(std::move(value), {}); }
    static Result Fail(std::string error) { return Result(T{}, std::move(error)); }
    explicit operator bool() const noexcept { return error_.empty(); }
    T& value() & { return value_; }
    const T& value() const & { return value_; }
    const std::string& error() const noexcept { return error_; }
private:
    Result(T value, std::string error) : value_(std::move(value)), error_(std::move(error)) {}
    T value_{}; std::string error_;
};
template<> class Result<void> {
public:
    static Result Ok() { return Result(std::string{}); }
    static Result Fail(std::string error) { return Result(std::move(error)); }
    explicit operator bool() const noexcept { return error_.empty(); }
    const std::string& error() const noexcept { return error_; }
private: explicit Result(std::string error) : error_(std::move(error)) {} std::string error_;
};
} // namespace airmuse
