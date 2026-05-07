# HynisLoader

**HynisLoader** là một tinh chỉnh jailbreak cho iOS giúp cho Minecraft: Bedrock edition load toàn bộ thư mục `renderer` có trong resource pack, hoạt động tương tự Draco Injector trên Android.

Tinh chỉnh hoạt động với **tất cả phiên bản Minecraft sử dụng RenderDragon engine**.

## Cách tinh chỉnh này hoạt động

Tinh chỉnh này hook hàm `fopen()` khi Minecraft gọi hàm này từ `libsystem_c.dylib` để chuyển hướng game sang load toàn bộ thư mục `renderer` bên trong pack đã được active trong `Global Resource Packs` thay vì load những file gốc tương ứng.

## Cách sử dụng

- Với thiết bị jailbreak, hãy tải tinh chỉnh này [ở đây](https://github.com/congcq/HynisLoader/releases) và cài đặt nó thông qua sileo/zebra.

- Với thiết bị không jailbreak (Jailed), hãy tải file `libhynisloader.dylib` [ở đây](https://github.com/congcq/HynisLoader/releases) và inject nó bằng `TrollFools` hoặc inject trực tiếp nó vào file thực thi chính của ipa thông qua một số ứng dụng sideload như Esign, Ksign, Feather,etc... và cài đặt ipa đã được inject qua việc ký chứng chỉ hoặc cài qua TrollStore (nếu có).

## Third party

- [fishhook](https://github.com/jevinskie/fishhook): [BSD-3 License](https://github.com/facebook/fishhook/blob/main/LICENSE)