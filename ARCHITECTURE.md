# Coto Down - 技术架构

## 🏗️ 三层解析策略

Coto Down 使用三层解析策略，确保最佳的兼容性和成功率：

```
┌─────────────────────────────────────────────────────────┐
│                    用户输入 URL                          │
└─────────────────────────────────────────────────────────┘
                          ↓
┌─────────────────────────────────────────────────────────┐
│              VideoResolverService                        │
│                  (统一入口)                               │
└─────────────────────────────────────────────────────────┘
                          ↓
┌─────────────────────────────────────────────────────────┐
│  策略 1: ExtractorManager (原生提取器)                    │
│  ✅ 最快、最可靠                                         │
│  ⚠️ 需要为每个平台实现提取器                             │
└─────────────────────────────────────────────────────────┘
                          ↓ (如果失败)
┌─────────────────────────────────────────────────────────┐
│  策略 2: VideoURLInterceptor (网络请求拦截)              │
│  ✅ 通用性强，不依赖页面结构                             │
│  ⚠️ 需要加载网页，较慢                                   │
└─────────────────────────────────────────────────────────┘
                          ↓ (如果失败)
┌─────────────────────────────────────────────────────────┐
│  策略 3: BackendResolver (外部 resolver)                 │
│  ✅ 支持所有网站                                         │
│  ⚠️ 需要服务器                                          │
└─────────────────────────────────────────────────────────┘
```

---

## 📦 核心组件

### 1. ExtractorManager (提取器管理器)

**位置:** `CotoDown/Extractors/ExtractorManager.swift`

**职责:**
- 管理所有平台提取器
- 路由请求到合适的提取器
- 提供统一的提取接口

**扩展方式:**
```swift
// 在 ExtractorManager 的 extractors 数组中添加新提取器
private let extractors: [VideoExtractor] = [
    YouTubeExtractor(),
    BilibiliExtractor(),
    TikTokExtractor(),      // 新增
    DouyinExtractor(),      // 新增
    XiaohongshuExtractor(), // 新增
]
```

---

### 2. VideoExtractor Protocol (提取器协议)

**位置:** `CotoDown/Extractors/ExtractorProtocol.swift`

**协议定义:**
```swift
protocol VideoExtractor {
    var platformName: String { get }
    func canExtract(url: String) -> Bool
    func extract(url: String) async throws -> ExtractionResult
}
```

**实现新提取器的步骤:**

1. **创建新文件:** `CotoDown/Extractors/PlatformExtractor.swift`
2. **实现协议:**
   ```swift
   final class PlatformExtractor: VideoExtractor {
       let platformName = "Platform"
       
       func canExtract(url: String) -> Bool {
           // 检查 URL 是否属于此平台
           guard let url = URL(string: url),
                 let host = url.host?.lowercased() else {
               return false
           }
           return host.contains("platform.com")
       }
       
       func extract(url: String) async throws -> ExtractionResult {
           // 1. 获取视频页面
           // 2. 提取视频信息（JSON/HTML）
           // 3. 解析格式和 URL
           // 4. 返回 ExtractionResult
       }
   }
   ```
3. **注册到 ExtractorManager**

---

### 3. 已实现的提取器

#### YouTubeExtractor

**文件:** `CotoDown/Extractors/YouTubeExtractor.swift`

**技术细节:**
- 请求 YouTube 视频页面
- 从 HTML 中提取 `ytInitialPlayerResponse` JSON
- 解析 `streamingData.formats` 和 `streamingData.adaptiveFormats`
- 处理签名加密（当前跳过加密格式）

**支持的格式:**
- 普通格式（包含音视频）
- 自适应格式（分离的音视频流）

**局限性:**
- 无法处理签名加密的格式（约 50% 的格式）
- 可能需要处理 throttling
- YouTube 经常更新，需要持续维护

---

#### BilibiliExtractor

**文件:** `CotoDown/Extractors/BilibiliExtractor.swift`

**技术细节:**
- 请求 B站视频页面
- 从 HTML 中提取 `window.__playinfo__` JSON
- 解析 DASH 格式（分离的音视频流）
- 解析 FLV/MP4 格式（合并的音视频）

**支持的格式:**
- DASH: H.264, H.265 视频流 + AAC 音频流
- FLV: 合并的视频流

**优势:**
- B站的格式相对稳定
- 不需要处理加密
- 公开视频成功率高

---

### 4. 待实现的提取器

#### TikTokExtractor

**实现思路:**
```swift
func extract(url: String) async throws -> ExtractionResult {
    // 1. 获取 TikTok 视频页面
    // 2. 提取 SIGI_STATE 或 RENDER_DATA
    // 3. 解析 JSON 获取视频 URL
    // 4. 返回结果
}
```

**关键数据:**
- `ItemModule.video.playAddr`
- `__UNIVERSAL_DATA_FOR_REHYDRATION__`

---

#### DouyinExtractor

**实现思路:**
```swift
func extract(url: String) async throws -> ExtractionResult {
    // 1. 获取抖音视频页面
    // 2. 提取 RENDER_DATA
    // 3. 递归查找视频数据对象
    // 4. 提取 playAddr 或 playApi
    // 5. 返回结果
}
```

**关键数据:**
- `RENDER_DATA` 元素
- `video.playAddr` 或 `video.playApi`

---

#### XiaohongshuExtractor

**实现思路:**
```swift
func extract(url: String) async throws -> ExtractionResult {
    // 1. 获取小红书笔记页面
    // 2. 提取 __INITIAL_STATE__
    // 3. 解析 note.noteDetailMap
    // 4. 提取 video.streaming.h264/h265
    // 5. 返回结果
}
```

**关键数据:**
- `__INITIAL_STATE__` 对象
- `note.video.streaming.h264[].masterUrl`

---

## 🔧 如何添加新平台支持

### 步骤 1: 分析目标网站

1. **打开浏览器开发者工具** (F12)
2. **访问视频页面**
3. **查看 Network 标签**，寻找视频请求
4. **查看 Elements 标签**，寻找 JSON 数据
5. **记录关键数据结构**

### 步骤 2: 创建提取器

```bash
# 创建新文件
touch CotoDown/Extractors/NewPlatformExtractor.swift
```

```swift
import Foundation

final class NewPlatformExtractor: VideoExtractor {
    let platformName = "NewPlatform"
    
    private let session: URLSession
    
    init() {
        let configuration = URLSessionConfiguration.default
        configuration.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 ..."
        ]
        self.session = URLSession(configuration: configuration)
    }
    
    func canExtract(url: String) -> Bool {
        guard let url = URL(string: url),
              let host = url.host?.lowercased() else {
            return false
        }
        return host.contains("newplatform.com")
    }
    
    func extract(url: String) async throws -> ExtractionResult {
        // 1. 获取页面
        guard let requestURL = URL(string: url) else {
            throw ExtractionError.invalidURL
        }
        
        let (data, _) = try await session.data(from: requestURL)
        guard let html = String(data: data, encoding: .utf8) else {
            throw ExtractionError.parseError("Could not decode page")
        }
        
        // 2. 提取 JSON 数据
        guard let jsonData = extractJSON(from: html) else {
            throw ExtractionError.parseError("Could not find video data")
        }
        
        // 3. 解析格式
        let formats = try parseFormats(from: jsonData)
        
        guard !formats.isEmpty else {
            throw ExtractionError.noFormatsFound
        }
        
        // 4. 提取标题和其他信息
        let title = extractTitle(from: html) ?? "Video"
        let thumbnail = extractThumbnail(from: html)
        
        // 5. 找到最佳格式
        let bestFormat = formats.max(by: { ($0.height ?? 0) < ($1.height ?? 0) })
        
        return ExtractionResult(
            title: title,
            thumbnailURL: thumbnail,
            duration: nil,
            formats: formats,
            bestFormat: bestFormat
        )
    }
    
    // MARK: - Private Methods
    
    private func extractJSON(from html: String) -> [String: Any]? {
        // 实现 JSON 提取逻辑
        // 使用正则表达式或字符串搜索
        return nil
    }
    
    private func parseFormats(from json: [String: Any]) throws -> [VideoFormat] {
        // 实现格式解析逻辑
        return []
    }
    
    private func extractTitle(from html: String) -> String? {
        // 提取标题
        return nil
    }
    
    private func extractThumbnail(from html: String) -> String? {
        // 提取缩略图
        return nil
    }
}
```

### 步骤 3: 注册提取器

在 `ExtractorManager.swift` 中添加：

```swift
private let extractors: [VideoExtractor] = [
    YouTubeExtractor(),
    BilibiliExtractor(),
    NewPlatformExtractor(),  // 新增
]
```

### 步骤 4: 测试

1. 编译项目
2. 测试新平台的视频链接
3. 检查是否成功提取
4. 处理错误情况

---

## 📊 提取器对比

| 提取器 | 速度 | 成功率 | 维护成本 | 复杂度 |
|--------|------|--------|----------|--------|
| YouTubeExtractor | 快 | 60-70% | 高 | 高 |
| BilibiliExtractor | 快 | 80-90% | 中 | 中 |
| VideoURLInterceptor | 慢 | 70-80% | 低 | 低 |
| BackendResolver | 中 | 90-95% | 高 | 高 |

---

## 🎯 最佳实践

### 1. 优先使用原生提取器
- 速度快
- 不需要加载页面
- 更可靠

### 2. 降级到 URL 拦截
- 通用性强
- 不依赖页面结构
- 适合未知平台

### 3. 最后使用外部 resolver
- 成功率最高
- 需要服务器
- 作为保底方案

---

## 🔮 未来规划

### 短期 (1-3个月)
- [ ] 实现 TikTok 提取器
- [ ] 实现抖音提取器
- [ ] 实现小红书提取器
- [ ] 优化 YouTube 提取器（处理签名）

### 中期 (3-6个月)
- [ ] 支持更多平台 (Twitter, Instagram)
- [ ] 实现格式选择功能
- [ ] 添加字幕支持
- [ ] 优化性能和内存使用

### 长期 (6-12个月)
- [ ] 支持 HLS/DASH 流合并
- [ ] 添加下载后处理（转码、合并）
- [ ] 实现批量下载
- [ ] 云端解析服务（可选）

---

## 📚 参考资源

### yt-dlp 源码
- https://github.com/yt-dlp/yt-dlp
- 查看 `yt_dlp/extractor/` 目录
- 每个平台的提取逻辑

### 逆向工程工具
- Chrome DevTools
- Charles Proxy
- mitmproxy
- Wireshark

### 学习资源
- YouTube API 文档
- B站开放平台
- 各平台开发者文档

---

## 💡 提示

### 开发新提取器时
1. **先手动分析网站**
   - 用浏览器查看页面源码
   - 找到视频数据的位置
   - 分析数据结构

2. **处理错误情况**
   - 网络错误
   - 解析错误
   - 格式不支持

3. **测试各种情况**
   - 公开视频
   - 私有视频
   - 不同格式
   - 不同地区

4. **保持代码简洁**
   - 每个提取器独立
   - 遵循协议
   - 易于维护

---

**开始添加新的平台支持吧！** 🚀
