#pragma once

#include "crypto.h"
#include "matcher.h"

#include <algorithm>
#include <cctype>
#include <fstream>
#include <string>
#include <vector>

constexpr size_t kTronAddressLen = 34;

inline bool isBase58AddressChar(char c) {
    return c != '\0' && std::strchr(kBase58, c) != nullptr;
}

inline void trimInPlace(std::string& s) {
    while (!s.empty() && std::isspace(static_cast<unsigned char>(s.back()))) s.pop_back();
    size_t i = 0;
    while (i < s.size() && std::isspace(static_cast<unsigned char>(s[i]))) ++i;
    if (i) s.erase(0, i);
}

inline bool isValidTemplateLine(const std::string& s) {
    if (s.size() != kTronAddressLen || s[0] != 'T') return false;
    for (char c : s) {
        if (!isBase58AddressChar(c)) return false;
    }
    return true;
}

// 与 Profanity 规则文件语义一致：模板行 + 全局 prefix/suffix 位数（按字符逐位相等）
inline bool addressMatchesTemplate(const std::string& addr, const std::string& tmpl,
                                   unsigned prefixCount, unsigned suffixCount) {
    if (addr.size() != kTronAddressLen || tmpl.size() != kTronAddressLen) return false;
    if (prefixCount + suffixCount == 0) return false;
    if (prefixCount + suffixCount > kTronAddressLen) return false;
    for (unsigned i = 0; i < prefixCount; ++i) {
        if (addr[i] != tmpl[i]) return false;
    }
    for (unsigned i = 0; i < suffixCount; ++i) {
        size_t idx = kTronAddressLen - 1 - i;
        if (addr[idx] != tmpl[idx]) return false;
    }
    return true;
}

inline MatchResult matchFromTemplates(const std::string& addr,
                                      const std::vector<std::string>& templates,
                                      unsigned prefixCount, unsigned suffixCount) {
    MatchResult r;
    for (const auto& tmpl : templates) {
        if (!addressMatchesTemplate(addr, tmpl, prefixCount, suffixCount)) continue;
        r.matched = true;
        r.kind = "模板";
        if (suffixCount > 0) {
            r.tail = addr.substr(kTronAddressLen - suffixCount);
            r.runLen = static_cast<int>(suffixCount);
        } else {
            r.tail = addr.substr(0, prefixCount);
            r.runLen = static_cast<int>(prefixCount);
        }
        return r;
    }
    return r;
}

struct MatchParams {
    const std::vector<std::string>* templates = nullptr;
    unsigned prefixCount = 0;
    unsigned suffixCount = 0;
    int legacyMinLen = 5;
    std::string exactSuffix;
};

inline bool tryMatchAddress(const std::string& addr, const MatchParams& p, MatchResult* out) {
    if (p.templates && !p.templates->empty()) {
        *out = matchFromTemplates(addr, *p.templates, p.prefixCount, p.suffixCount);
        return out->matched;
    }
    if (!p.exactSuffix.empty()) {
        if (!addressEndsWith(addr, p.exactSuffix)) return false;
        out->matched = true;
        out->kind = "后缀";
        out->runLen = static_cast<int>(p.exactSuffix.size());
        out->tail = p.exactSuffix;
        return true;
    }
    *out = evaluateAddress(addr, p.legacyMinLen);
    return out->matched;
}

inline int effectiveGpuMinLen(const MatchParams& p) {
    if (p.templates && !p.templates->empty()) {
        if (p.suffixCount >= 2) {
            bool allSameSuffix = true;
            const auto& t0 = (*p.templates)[0];
            for (const auto& tmpl : *p.templates) {
                for (unsigned i = 0; i < p.suffixCount; ++i) {
                    size_t idx = kTronAddressLen - 1 - i;
                    if (tmpl[idx] != t0[idx]) {
                        allSameSuffix = false;
                        break;
                    }
                }
                if (!allSameSuffix) break;
            }
            if (allSameSuffix) {
                bool allSameChar = true;
                char c = t0[kTronAddressLen - 1];
                for (unsigned i = 1; i < p.suffixCount; ++i) {
                    if (t0[kTronAddressLen - 1 - i] != c) {
                        allSameChar = false;
                        break;
                    }
                }
                if (allSameChar) return static_cast<int>(p.suffixCount);
            }
            return static_cast<int>(p.suffixCount);
        }
        return 2;
    }
    if (!p.exactSuffix.empty()) return std::max(p.legacyMinLen, minLenHintForSuffix(p.exactSuffix));
    return p.legacyMinLen;
}

inline bool loadMatchingInput(const std::string& pathOrLine, std::vector<std::string>* out,
                              std::string* err) {
    out->clear();
    std::ifstream f(pathOrLine);
    if (f.good()) {
        std::string line;
        while (std::getline(f, line)) {
            trimInPlace(line);
            if (line.empty() || line[0] == '#') continue;
            if (!isValidTemplateLine(line)) {
                if (err) *err = "无效模板行（须 34 位、T 开头、Base58 字符）: " + line;
                return false;
            }
            out->push_back(line);
        }
        if (out->empty()) {
            if (err) *err = "匹配文件无有效行: " + pathOrLine;
            return false;
        }
        return true;
    }
    std::string one = pathOrLine;
    trimInPlace(one);
    if (!isValidTemplateLine(one)) {
        if (err) *err = "不是有效 TRON 模板地址（34 位）或可读文件: " + pathOrLine;
        return false;
    }
    out->push_back(one);
    return true;
}
