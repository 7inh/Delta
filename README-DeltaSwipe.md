# DeltaSwipe

Fork của [Delta](https://github.com/rileytestut/Delta) (Riley Testut) — emulator iOS — với **lớp điều khiển cảm ứng làm lại cho nốt**: chơi bằng **cử chỉ vuốt** thay vì bấm nút ảo, kèm **autofire / double-tap toggle** cấu hình được. Mục tiêu đầu tiên: chơi **Snow Bros (NES)** trên iPhone thoải mái.

> **License:** dự án gốc phát hành theo **AGPL-3.0** (xem `COPYING`). Fork này giữ nguyên license. Bản build/sideload của bạn **phải** kèm nguồn: dẫn link về repo này hoặc upstream Delta. Credit đầy đủ: Riley Testut & Delta contributors; DeltaCore + các core (Nestopia UE, mGBA, Snes9x, mupen64plus, melonDS, Genesis Plus GX…).

## Tính năng mới: Swipe Controls

Bật trong **Settings → Controls → Swipe Controls**. Khi bật (mặc định cho mọi hệ máy có touch controls):

| Cử chỉ | Hành động |
|---|---|
| Vuốt ← / → | Di chuyển. Mặc định **Sticky**: cứ chạy tới khi vuốt ngược lại, tap nhẹ để dừng |
| Vuốt ↑ | Nhảy (giữ ngón tiếp tục đẩy lên để giữ nút A lâu hơn) |
| Vuốt ↓ | Mặc định = dừng lại (có thể đổi thành bấm Down / bỏ qua) |
| Double-tap | Bật/tắt **autofire** (bắn liên tục) |
| Chạm Start / Select / Menu trên skin | Vẫn hoạt động bình thường (pass-through) |

Tùy chọn cấu hình: layout (vuốt toàn vùng hoặc chia đôi trái di chuyển / phải bắn-giữ), sticky vs hold, 8 hướng, ngưỡng vuốt, nút jump/fire (A/B), autofire luôn bật hay chỉ double-tap, tốc độ autofire (2–15Hz), thời lượng nhảy, hint hiển thị, haptics.

Kiến trúc (đều nằm ở app target, không đụng core/save/ROM):

- `Delta/Emulation/SwipeInputEngine.swift` — logic cử chỉ thuần (không UIKit, test được headless)
- `Delta/Emulation/SwipeGameController.swift` — `GameController` phát input domain `.controller(.swipe)`; `SwipeInputMapping` đổi sang input hệ máy (cùng pattern với `ControllerViewInputMapping`)
- `Delta/Emulation/SwipeControlsOverlayView.swift` — view phủ trên `ControllerView`, nhận multi-touch, `hitTest` pass-through các item skin không do gesture đảm nhiệm (Start/Select/Menu/touch screen DS/L/R…), CADisplayLink 60Hz cho autofire, hint + haptics
- `Delta/Settings/Features/SwipeControls.swift` — options dùng `@Option` của DeltaFeatures; đăng ký `@Feature` trong `Delta/Settings/Features/Features.swift`
- `Delta/Emulation/SwipeControlsSettingsView.swift` — UI cấu hình (Settings → Controls → Swipe Controls)
- Tích hợp: `Delta/Emulation/GameViewController.swift` (`prepareSwipeControls`, `updateControllers`, KVO state, settingsDidChange) và `Delta/Scenes/SceneDelegate.swift` (debug import, xem dưới)

Lưu ý upstream đã vá khi build với Xcode 27:

- `Sources/Paywalls/PaywallColor.swift` (RevenueCat 5.8.0) lỗi synthesized memberwise init với Swift 6.2 → nâng pin `purchases-ios-spm` lên **5.91.0** trong `project.pbxproj`
- `Cores/SNESDeltaCore/snes9x/conffile.{h,cpp}` comparator thiếu `const` với libc++ mới → đã thêm `const`
- Deployment target các Pods/subproject < 15.0 bị Xcode 27 từ chối → đã bump lên 15.0 (chỉ working tree; nếu `pod install` lại, nhớ `post_install` trong `Podfile` set 15.0)

## Build (Xcode 27)

```bash
git clone https://github.com/7inh/Delta.git DeltaSwipe   # hoặc repo fork của bạn
cd DeltaSwipe
git checkout swipe-controls

# Submodule dùng URL SSH — đổi sang HTTPS rồi init
git config url."https://github.com/".insteadOf "git@github.com:"
git submodule update --init --recursive

# LFS assets (skin hình, v.v.)
git lfs install
git submodule foreach --recursive 'git lfs pull || true'

open Delta.xcworkspace    # ĐỪNG mở .xcodeproj — project dùng CocoaPods
# Chọn scheme "Delta" → iPhone simulator → Run.
```

Team signing: `Delta` target đã đặt `DEVELOPMENT_TEAM = NK8KQXCK9X`, bundle id `com.leelinh.DeltaSwipe`. Đổi thành team của bạn nếu cần (Target Delta → Signing & Capabilities). Entitlements rỗng nên không cần capability đặc biệt.

## Sideload (không jailbreak)

1. **Xcode trực tiếp** (đơn giản nhất): mở workspace, chọn device thật, sản phẩm lên máy (free account: app hết hạn sau 7 ngày; paid team: 1 năm).
2. **.ipa + AltStore/SideStore**: `Product → Archive` → `Distribute App → Ad Hoc/Development` (cần UDID trong profile) → cài qua AltStore.

## Debug import ROM (automation)

Đã thêm scheme URL `deltaswipe` (chỉ `#if DEBUG`):

```
xcrun simctl openurl booted "deltaswipe://import?path=/Users/ME/Downloads/Snow%20Brothers%20(USA).nes"
```

(app đọc file, import qua `DatabaseManager.importGames`, log ra console). Trên máy thật nên import qua Files/AirDrop như Delta thường.

## Test

```bash
# Logic engine (không cần simulator):
swiftc -O Delta/Emulation/SwipeInputEngine.swift Tests/SwipeControls/main.swift -o /tmp/engine-tests && /tmp/engine-tests
```

30 checks: sticky/hold direction, jump pulse, autofire duty cycle, double-tap window, reset, isIdle, swipe-down action, split fire zone, 8-way.
