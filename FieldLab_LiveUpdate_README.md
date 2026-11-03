# FIELD LAB v8.6.0 Live Update

## Khởi chạy lần đầu

1. Chạy `FieldLab_QuickStart.lua` trong executor của bạn (không cần file phụ).
2. Bản mặc định v8.6.0 được nhúng trong loader. Bật/tắt Auto Update tại Config > LIVE UPDATE.
3. Vào cùng game khi loader hoạt động. Không chạy thêm `FieldLab_live.lua` đè lên loader.

## Cập nhật từ file cục bộ

- Cần executor hỗ trợ `readfile` / `writefile`.
- Lưu nội dung phiên bản mới thành `FieldLab_live.lua` trong đúng thư mục workspace của executor.
- Sau tối đa 15 giây, loader so sánh nội dung, biên dịch và thay app nếu hợp lệ (chế độ này hoạt động khi `REMOTE_BASE` để trống).
- Script nguồn phải có dòng `-- FIELDLAB_BUILD: x.y.z` tương ứng, không chấp nhận version cũ hơn.

## Cập nhật tự động qua GitHub

1. Tạo repo GitHub do bạn quản lý, công khai hoặc có phân phối HTTPS riêng bạn tin cậy.
2. Upload `FieldLab_live.lua` và `fieldlab_manifest.json` ở cùng thư mục root hoặc branch.
3. Repo này đã cấu hình sẵn `REMOTE_BASE = "https://raw.githubusercontent.com/ERINARR/FieldLab/main"` trong `FieldLab_QuickStart.lua`. Không cần chỉnh URL.
4. Chạy `FieldLab_QuickStart.lua` trong repo này một lần. Khi có bản mới, commit `FieldLab_live.lua` và cập nhật `fieldlab_manifest.json` cùng phiên bản và SHA-256 để loader nhận bản mới.

**Lưu ý:** Tao không có quyền tự tải code lên GitHub hoặc vào Roblox của mày. Các file tải trong ChatGPT không tự xuất hiện trên máy hay repo.

## Cách cập nhật từ v8.5.x

- Lần đầu chạy loader phải thay phiên đang chạy v8.5.x (GUI mới sẽ dọn GUI cũ).
- Sau đó chỉ cập nhật app trong repo / thư mục executor.
- Khi reload, cấu hình Farm, Combat, Quest, Planter, Blender và tab đang mở sẽ được khôi phục. Các vòng Auto Farm/Combat/Quest đang chạy sẽ **dừng**, cần bật lại, để tránh script cũ và mới tranh quyền điều khiển.
- Nếu bản mới không biên dịch được hoặc báo lỗi trong giai đoạn khởi tạo đồng bộ, loader thử rollback sang bản đang chạy trước đó. Lỗi phát sinh sau đó ở các task bất đồng bộ có thể không được phát hiện tự động.
- `getgenv`, `readfile`, `loadstring`, `game:HttpGet` là tính năng phụ thuộc môi trường/executor; Roblox Studio/LocalScript thông thường không cung cấp đầy đủ.

## Tài liệu trong gói

- `FieldLab_QuickStart.lua`: file chạy một lần, đã nhúng app.
- `FieldLab_live.lua`: mã nguồn app chính, có thể thay bằng bản mới.
- `fieldlab_manifest.json`: phiên bản và SHA256 cho cập nhật qua repo.

Security: chỉ trỏ nguồn cập nhật tới repo tự kiểm soát. Mã nguồn từ URL sẽ được thực thi trên máy; chỉ bật remote khi tin tưởng tuyệt đối host đó.