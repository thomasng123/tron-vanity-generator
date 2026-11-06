#pragma once

#include "crypto.h"
#include "matcher.h"

#include <algorithm>
#include <cctype>
#include <cstring>
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
    // 后缀表走内核二分查找时，vanity min_len 不用；仍返回合法下限供未启用表时回退。
    if (p.templates && !p.templates->empty()) {
        if (p.prefixCount > 0) return 2;  // 前缀仍只能靠 host 复核，GPU 用宽松靓号预筛
        if (p.suffixCount >= 2) return static_cast<int>(p.suffixCount);
        return 2;
    }
    if (!p.exactSuffix.empty()) return std::max(p.legacyMinLen, minLenHintForSuffix(p.exactSuffix));
    return p.legacyMinLen;
}

// GPU 内核 base58_tail 的 tc[0] = 地址最末字符。打包时把后缀反转，便于与 tc 直接 memcmp。
// 仅支持「纯后缀」：模板 suffixCount>0 且 prefixCount==0，或 --suffix。
// 返回 false 表示本批仍走 vanity 预筛（sufN 置 0）。
inline bool buildGpuSuffixTable(const MatchParams& p, std::vector<unsigned char>* flat,
                                unsigned* sufLen, unsigned* sufN) {
    flat->clear();
    *sufLen = 0;
    *sufN = 0;

    std::vector<std::string> rows;
    if (p.templates && !p.templates->empty() && p.suffixCount > 0 && p.prefixCount == 0) {
        const unsigned len = p.suffixCount;
        if (len > 12) return false;  // 与内核 TAIL 对齐
        rows.reserve(p.templates->size());
        for (const auto& tmpl : *p.templates) {
            if (tmpl.size() != kTronAddressLen) continue;
            std::string rev(len, '\0');
            for (unsigned i = 0; i < len; ++i)
                rev[i] = tmpl[kTronAddressLen - 1 - i];
            rows.push_back(std::move(rev));
        }
    } else if (!p.exactSuffix.empty() && p.prefixCount == 0 &&
               (!p.templates || p.templates->empty())) {
        const unsigned len = static_cast<unsigned>(p.exactSuffix.size());
        if (len == 0 || len > 12) return false;
        std::string rev(len, '\0');
        for (unsigned i = 0; i < len; ++i)
            rev[i] = p.exactSuffix[len - 1 - i];
        rows.push_back(std::move(rev));
    } else {
        return false;
    }

    if (rows.empty()) return false;
    std::sort(rows.begin(), rows.end());
    rows.erase(std::unique(rows.begin(), rows.end()), rows.end());

    const unsigned len = static_cast<unsigned>(rows[0].size());
    flat->resize(static_cast<size_t>(rows.size()) * len);
    for (size_t i = 0; i < rows.size(); ++i)
        std::memcpy(flat->data() + i * len, rows[i].data(), len);
    *sufLen = len;
    *sufN = static_cast<unsigned>(rows.size());
    return true;
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
