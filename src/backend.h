#pragma once
#include <atomic>
#include <cstdint>
#include <functional>
#include <memory>
#include <string>
#include <vector>

#include "match_rules.h"
#include "matcher.h"

struct RunConfig {
    int minLen = 5;
    unsigned int threads = 0;      // 0 = 自动
    uint64_t maxAttempts = 0;      // 0 = 无限
    uint64_t maxMatches = 0;       // 0 = 无限；1 = 命中一条即停
    std::string suffix;            // 非空：地址必须以此字符串结尾（与 --matching 互斥）
    std::vector<std::string> matchingTemplates;  // --matching 文件或单地址模板行
    unsigned prefixCount = 0;      // 模板前缀匹配位数（与 Profanity 语义一致）
    unsigned suffixCount = 0;      // 模板后缀匹配位数
    bool verbose = false;
};

inline MatchParams matchParamsFromRunConfig(const RunConfig& cfg) {
    MatchParams p;
    if (!cfg.matchingTemplates.empty()) p.templates = &cfg.matchingTemplates;
    p.prefixCount = cfg.prefixCount;
    p.suffixCount = cfg.suffixCount;
    p.legacyMinLen = cfg.minLen;
    p.exactSuffix = cfg.suffix;
    return p;
}

struct FoundKey {
    std::string address;
    std::string privHex;
    MatchResult match;
};

// 全局运行状态（所有 backend 共享）
struct RunState {
    std::atomic<uint64_t> checked{0};
    std::atomic<uint64_t> found{0};
    std::atomic<bool> stop{false};
};

using ReportFn = std::function<void(const FoundKey&)>;

// 供报告展示用的多行硬件信息。
struct BackendInfo {
    std::string kind;               // "CPU" / "GPU"
    std::string title;              // 型号，如 "12th Gen Intel(R) Core(TM) i5-12400"
    std::vector<std::string> lines; // 细节行，如 {"12 threads", "AVX2   OK"}
};

class Backend {
public:
    virtual ~Backend() = default;
    virtual std::string name() const = 0;         // 简短标签，如 "CPU" / "OpenCL GPU"
    virtual bool available() const = 0;
    virtual std::string note() const { return ""; }  // 不可用/受限原因
    virtual BackendInfo info() const = 0;

    // 运行约 seconds 秒的压测，返回 keys/sec；不写文件、不触发回调
    virtual double benchmark(double seconds) = 0;

    // 主运行循环；持续调用 report 直到 state.stop 或达到 maxAttempts
    virtual void run(const RunConfig& cfg, RunState& state, const ReportFn& report) = 0;
};

struct GpuDevice;  // hwdetect.h
std::unique_ptr<Backend> makeCpuBackend();
// CPU 压测（threads=0 表示用逻辑核数）；不含地址匹配回调，测完整 secp256k1+地址流水线
double cpuTimedBenchmark(double seconds, unsigned int threads = 0);
std::unique_ptr<Backend> makeGpuBackend(const GpuDevice& dev);

inline void noteAcceptedMatch(const RunConfig& cfg, RunState& state, const ReportFn& report,
                              const FoundKey& fk) {
    (void)cfg;
    state.found.fetch_add(1, std::memory_order_relaxed);
    report(fk);
    if (cfg.maxMatches && state.found.load(std::memory_order_relaxed) >= cfg.maxMatches)
        state.stop.store(true, std::memory_order_relaxed);
}
