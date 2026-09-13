# ChengIOS

Tweak jailbreak giả lập phiên bản iOS, phiên bản app và một số tín hiệu thiết bị theo từng ứng dụng. Mục đích chính là giúp máy cũ vẫn mở được app yêu cầu iOS/app version mới hơn.

Cần iPhone/iPad đã jailbreak. Build cần [Theos](https://theos.dev) và [AltList](https://github.com/opa334/AltList).

## Nguồn Sileo

Thêm nguồn:

```
https://raw.githubusercontent.com/vinhnv2507/ChengIfoIOS/gh-pages
```

Rồi tìm **ChengIOS** (`com.vinhnv2507.chengios`). Có hai gói:

- Rootful: `iphoneos-arm`
- Rootless (Dopamine / palera1n): `iphoneos-arm64`

## Hook

- `NSProcessInfo` / `UIDevice` phiên bản iOS và build
- `sysctlbyname` `kern.osproductversion`, `kern.osversion`
- User-Agent kiểu Safari trên `NSURLRequest`, `NSURLSessionConfiguration`, WebKit
- `NSBundle` `CFBundleShortVersionString` / `CFBundleVersion` của app chính
- Tên máy, hostname, vendor ID, advertising ID
- Model (`UIDevice`, `uname`, `hw.machine`) nếu đã điền
- Locale, múi giờ, nhà mạng (tắt mặc định)
- Vị trí `CLLocationManager` (tọa độ cố định hoặc GPX, tắt mặc định)
- `getifaddrs` IPv4/IPv6/MAC (best-effort, tắt mặc định)
- Wi-Fi SSID/BSSID/gateway qua `CNCopyCurrentNetworkInfo` / `NEHotspotNetwork`

Kích thước màn hình không bị đổi.

## 1.2.21

- Facebook/Shopee: quay lai an toan kieu 1.2.14. Khong hook `MGCopyAnswer`, khong spoof iOS/Darwin/IDFV/locale/network (vang du tat Spoof sau o 1.2.20)
- Van doi model qua `hw.machine` / `uname` / `UIDevice` de Facebook hien may gia
- ADIA64/app thuong: van hook Gestalt/sysctl luc load (khong bo qua vi prefs chua san)
- Giu backup/restore uid 501 cua 1.2.20

## 1.2.20

- Keychain dump/restore chay `chengioskc` **uid 501** (mobile), giong Apps Manager `kcaccess.bin`. Ban 1.2.19 dump bang root nen SecItem = 0, restore mat login
- Dump keychain **truoc khi kill app**, copy toan bo child trong container (khong chi Documents/Library/tmp)
- Spoof iOS/model/Gestalt/UA cho app da chon, ke ca Facebook/Shopee/ADIA64/Safari. Khong inject WebContent. Safari van khong spoof Wi-Fi/IP
- Change Apps: mot danh sach (Safari/SafariViewService/Web App nam trong list, khong pin tren dau)
- Quan ly Backup chi con danh sach restore/rename/delete. Backup/Xoa/Random o man hinh chinh
- Backup cu 1.2.19 khong giu login. Cai ldid, Respring, backup lai khi dang nhap, can `Keychain N>0` va `kcUid 501`

## 1.2.19

- Keychain dump/restore/wipe theo Apps Manager: binary `chengioskc` (kieu `kcaccess.bin`), **khong** dung `keychain-access-groups: *`
- Doc DISTINCT agrp tu `keychain-2.db` (`genp`/`inet`/`keys`/`cert`), `ldid -S` agrp that vao **ban copy** `chengioskc`, spawn process moi
- SecItem dump decrypted `genp` + `inet` + `keys` + `cert` + `identity` (Facebook Limited Login P-256 nam o class key)
- Restore uu tien SecItemAdd data da giai ma; SQL blob chi khi SecItem = 0 (backup cu 1.2.18)
- Wipe: SecItemDelete theo tung agrp/class, roi SQL, pass 2 sau `securityd`
- Can cai `ldid` (Procursus hoac `am.ldid` cua Apps Manager). Sau backup can `Keychain N>0`, `Root CO`, `Daemon CO`, `ldid CO`
- Backup cu 1.2.18 `Keychain=0` khong giu login Facebook/Shopee/TikTok; backup lai bang 1.2.19 khi dang dang nhap, tu app ChengIOS

## 1.2.18

- Backup/restore/xoa data luon chay root: in-process neu uid 0, setuid `chengiosroot`, hoac LaunchDaemon inbox (Dopamine nosuid)
- App ChengIOS `chmod 6755` kieu Filza/Apps Manager; daemon `chengiosroot daemon` xu ly job `/var/mobile/Media/ChengIOS/.work/inbox`
- Dump keychain: copy `keychain-2.db` + WAL, query agrp ro (khong dung `*`), Facebook DBL / msysstorage / metaplatforms
- Restore: chen lai row SQL `genp`/`inet` sau khi DELETE agrp+svce+acct (cung may, giu cookie/phien). SecItem chi khi SQL=0
- Xoa Facebook: quet moi App Group MCM, `StoreKit`, group `msysstorage` + `metaplatforms.family`, pass 2 sau khi kill cfprefsd/securityd
- Khong xoa Instagram/WhatsApp khi chi chon Facebook. Khong match bare team `43AQTK3442`
- Sau backup can `Keychain: N>0`, `Root: CO` / uid 0 (Daemon CO). Backup cu Keychain=0 thi backup lai bang 1.2.18

## 1.2.17

- Root helper `chengiosroot` (setuid uid 0) cho backup / restore / xoa data
- Dump + restore + wipe keychain bang SecItem (khi chay root) va SQLite `keychain-2.db` (bang `genp` / `inet`) de giu cookie / phien dang nhap Facebook, Shopee, TikTok
- Xoa Facebook / TikTok / Shopee sach hon: companion app, app group, Application Support, accountsd
- Sau backup, can thay `Keychain: N item` > 0 va `Root: CO`. Neu N=0 hoac Root KHONG thi restore se mat login: cai lai 1.2.17, Respring, backup tu app ChengIOS (khong dung Settings)
- Restore xong force-quit app roi mo lai. iCloud Keychain AutoFill van co the goi y username

## 1.2.16

- Backup/restore/xoa data theo ControlIOS: copy 4 thu muc `Documents`, `Library`, `tmp`, `SystemData`; khong xoa metadata container
- Copy chiu loi tung file (bo socket/fifo); khong skip `tmp`/`Caches` de Shopee con session
- Restore `chown 501:501`; kill `cfprefsd` de Preferences khong ghi de lai
- Xoa Facebook: empty tung file trong Library, xoa keychain token theo service biet truoc, xoa kem Messenger

## 1.2.15
- Backup app kem keychain + plugin + Caches de restore Facebook/Shopee con dang nhap
- Xoa Facebook sach hon: family group, plugin, keychain SSO (khong con chi logout)
- Xoa duoc Safari (history/cookies/website data)
- Nut xoa toan bo app user + Safari (khong phai Restore iOS, giu jailbreak)
- Xoa data roi random info: `chengios://erase-random-all`, `chengios://erase-device-random`

## 1.2.14
- Facebook/Shopee: không hook `MGCopyAnswer` khi bật Spoof sâu (nguyên nhân văng FB/Shopee/Hồ sơ)
- Vẫn đổi model qua `hw.machine` / `uname` / `UIDevice` để Facebook hiện máy giả, không cần Spoof sâu
- Spoof sâu chỉ còn Gestalt/Darwin/RAM/board-id trên app thường; gọi orig trước khi thay chuỗi để đủ `typeCode`
- `HW_MODEL` (board-id) không spoof trên Facebook/Shopee

## 1.2.13
- Facebook/Shopee: spoof model that (`hw.machine` / `uname` / ProductType) de Facebook khong con hien iPhone that
- Van khong spoof iOS version / Darwin / IDFV trong Facebook de tranh crash
- Erase Facebook xoa app group family + keychain token, ke ca khi dang cai Messenger

## 1.2.12
- Backup/restore/erase on dinh hon: 1 thu muc chinh `/var/mobile/Media/ChengIOS/Backups`, van nhin backup o Documents neu co
- Restore ho so ghi de toan bo prefs (khong merge so le)
- Erase sach hon: sandbox + snapshot + Saved State + keychain app (best-effort). Group chia se voi app khac thi giu
- Deeplink backup/erase theo bundle: `chengios://backup-apps?bundle=com.facebook.Facebook`
- Chon 1 app khi xoa neu dang chon nhieu app

## 1.2.11

- Quan ly backup / restore ho so ChengIOS
- Backup kem data app da chon (Documents, Preferences, Cookies; bo Caches/tmp)
- Xoa sach sandbox app da chon (khong xoa Safari / keychain iCloud)
- Deeplink: `chengios://backup`, `chengios://backup-profile`, `chengios://backup-apps`, `chengios://restore-latest`, `chengios://restore?id=...&data=1`, `chengios://erase-apps`, `chengios://erase?bundle=com.facebook.Facebook`
- Backup luu tai `/var/mobile/Media/ChengIOS/Backups`

## 1.2.10

- Safari GPS: bam Detect tren deviceinfo.me (Region/City/ISP van la IP cong cong that)
- Ho so hien User-Agent
- Deeplink chuyen vao muc con; Respring + Refresh len dau
- Random theo vung: US/KR/JP... doi locale, GPS, nha mang, Wi-Fi, LAN/IPv6 cho khop

## 1.2.9

- Sua crash-loop Safari cua 1.2.8: khong inject WebContent, khong spoof iOS version ben trong Safari
- Safari chi doi User-Agent mot lan (`customUserAgent`); AIDA64 van spoof native
- Tat ChengIOS thi khong gan WebKit hooks

## 1.2.8

- Safari (deviceinfo.me / JS `navigator.userAgent`) nhận spoof: inject WebContent của Safari, `customUserAgent` + script document-start
- WebContent của Facebook/Shopee vẫn không hook
- AIDA64 vốn đã nhận vì là app native; Safari cần force-quit hẳn rồi mở lại tab

## 1.2.7

- Facebook/Shopee: chế độ an toàn, không hook `sysctlbyname` / `uname` / `getifaddrs`, không giả version app
- **Giả lập phiên bản App mặc định tắt**; không còn fallback `2147483647` (nguyên nhân văng FB/Shopee dù tắt Spoof sâu)
- Không inject WebContent (captcha Shopee)
- `isOperatingSystemAtLeastVersion` giữ bản iOS thật trên FB/Shopee để tránh gọi API không có

## 1.2.6

- Safari **luôn** nằm đầu **Change Apps** (kể cả khi hệ thống ẩn app)
- App ChengIOS trên Home đủ mục giống Settings: app, random, info, iOS, locale, GPS, Wi-Fi, serial/UDID/IMEI, deeplink, respring
- Sửa crash Facebook/Shopee của 1.2.5: bỏ hook `sysctl` thô, không hook WebContent, `MGCopyAnswer` 2-arg và chỉ gắn khi bật Spoof sâu
- **Spoof sâu (Gestalt / Darwin) mặc định tắt** — bật rồi force-quit app đích nếu cần sâu hơn
- Random Toàn Bộ không tự bật giả version app (Facebook/Shopee dễ văng nếu đổi `CFBundleVersion`)
- Deeplink thêm `chengios://apps`

## 1.2.5


- Spoof sâu hơn trong app đã chọn: `MGCopyAnswer` (ProductType, board, serial, UDID, IMEI, Wi-Fi/BT MAC)
- Darwin `uname` / `sysctl` / `sysctlbyname` (`kern.osrelease`, `hw.machine`, `hw.model`, RAM, ncpu)
- IDFV / IDFA / serial / UDID ổn định đến lần Random tiếp
- `CTTelephonyNetworkInfo` radio access (LTE/5G) + `CFLocale` / `CFTimeZone`
- Vẫn không hook SpringBoard, không đổi kích thước màn hình

## 1.2.4


- App **ChengIOS** trên màn hình chính: Random, xem hồ sơ, sao chép, mở Settings
- URL scheme `chengios://` cho Shortcuts / deeplink
- `chengios://random-identity` = Random Info Máy
- `chengios://random-all` = Random Toàn Bộ
- `chengios://profile`, `chengios://copy`, `chengios://settings`
- `?silent=1` không hiện alert; `x-success=` cho x-callback-url
- `uicache` sau khi cài để hiện icon

## 1.2.3

- Random Toàn Bộ thêm Wi-Fi: SSID, BSSID, gateway, RSSI khớp vùng và subnet IPv4
- Hook `CNCopyCurrentNetworkInfo` / `NEHotspotNetwork` để app đọc SSID/BSSID đã gán
- Trang **Hồ sơ hiện tại** để xem lại info đã random, có sao chép

## 1.2.2

- **Random Info Máy**: chọn 1 hồ sơ thiết bị thật (model + tên + hostname + iOS/build khớp nhau)
- **Random Toàn Bộ**: điền thêm locale, nhà mạng, GPS, LAN IPv4/IPv6/MAC và version app theo đúng vùng
- Không trộn locale Nhật với Viettel, không gán iOS 26 cho iPhone 11, iPhone 17 không chạy iOS 18
- Version app random dạng `x.y` / `x.y.z`, không dùng `2147483647`

## 1.2.1

- Không hook SpringBoard, Settings và daemon hệ thống — sửa watchdog Dopamine của 1.2.0
- Tương thích prefs ChengIOS 1.0.1: `appEnabled`, `spoofedSystemVersion`, `spoofedBuild`, `spoofedName`, `spoofedHostname`, `spoofedModel`
- **Change Apps** và **Change Info** giữ nguyên lối dùng cũ
- Thêm danh sách **Spoofed Apps** (AltList)
- Prefs reload qua Darwin `com.vinhnv2507.chengiosprefs/changed` và `.../ReloadPrefs`
- Có thể nhập đúng phiên bản/build iOS
- Giả lập phiên bản app qua `NSBundle`, không chỉ User-Agent
- Module locale/nhà mạng/vị trí/mạng (opt-in)
- Gói rootful và rootless

Vị trí và mạng **tắt** cho đến khi bạn bật và điền giá trị. App không được chọn thì không bị sửa.

## Cài đặt

Mở app **ChengIOS** trên màn hình chính, hoặc **Cài đặt → ChengIOS**.

1. Để **Bật ChengIOS** sáng.
2. Chọn app trong **Change Apps** (danh sách 1.0.1) hoặc **Spoofed Apps**.
3. Bấm **Random Info Máy** hoặc **Random Toàn Bộ**, hoặc vào **Change Info** để điền tay.
4. Tùy chọn: bật giả lập phiên bản app, locale, nhà mạng, vị trí, mạng/Wi-Fi.
5. Force-quit app đích (hoặc Respring) sau khi đổi setting.

**Random Info Máy** chỉ đổi định danh: model, tên, hostname, iOS, build. **Random Toàn Bộ** thêm locale, nhà mạng, GPS, LAN, Wi-Fi và version app, cùng một vùng.

Nếu cài xong không thấy icon, Respring hoặc chạy `uicache -p /var/jb/Applications/ChengIOSApp.app` (rootless) / `uicache -p /Applications/ChengIOSApp.app` (rootful).

### Deeplink / Shortcuts

Thêm thao tác **Mở URL**:

- `chengios://random-identity` — Random Info Máy
- `chengios://random-all` — Random Toàn Bộ
- `chengios://apps` — mở Change Apps
- `chengios://random-all?silent=1` — Random Toàn Bộ, không alert
- `chengios://profile` — xem hồ sơ hiện tại
- `chengios://copy` — sao chép hồ sơ
- `chengios://settings` — mở Settings
- `chengios://x-callback-url/random-all?x-success=shortcuts://`

Alias: `random-info`, `info-may`, `toan-bo`, `hoso`, `prefs`. Query `mode=identity` / `mode=all`.

### Vị trí

- Cần **Giả lập vị trí** cộng latitude/longitude, hoặc file GPX đọc được.
- Điểm GPX `trkpt` lặp lại theo offset `<time>` nếu có, không thì 1 giây/điểm.
- Ví dụ: `/var/mobile/Media/ChengIOS/route.gpx`

### Mạng

- Cần **Giả lập định danh mạng** và ít nhất một trong IPv4, IPv6, MAC, SSID, BSSID.
- Interface mặc định `en0`. Dùng `*` cho mọi interface không phải loopback.
- iOS hiện tại không có API Wi-Fi MAC được hỗ trợ. Hook MAC không đảm bảo phủ hết.

## Build

```sh
# rootful
make package FINALPACKAGE=1

# rootless
make clean
make package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=rootless
```

Push lên `main` của [ChengIfoIOS](https://github.com/vinhnv2507/ChengIfoIOS) thì GitHub Actions build hai `.deb` và cập nhật nguồn `gh-pages`.

Depends: Cydia Substrate / ElleKit (`mobilesubstrate`), PreferenceLoader, AltList.

## Lưu ý

- Phiên bản iOS tự động chỉ là heuristic theo ngày, không phải API của Apple. App khó tính thì nên nhập tay.
- Vendor/advertising ID random theo process khi bật module định danh.
- Tweak không giấu jailbreak và không vượt kiểm tra phía server.
- Hãy thử module vị trí/mạng trên app test trước.

## License

MIT. Phần OS version spoof gốc của Fadexz; ChengIOS do vinhnv2507 phát triển tiếp.
