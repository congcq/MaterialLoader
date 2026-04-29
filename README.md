> [!Note]
> Hiện tại dự án còn mới và tiềm ẩn lỗi vặt. Nếu gặp bất cứ lỗi nào hãy báo ngay với chúng tôi, chúng tôi sẽ fix nếu có thể.
> Bạn cũng có thể đóng góp vào dự án này.

# Material Loader

**Material Loader** là một tinh chỉnh jailbreak cho iOS giúp cho Minecraft: Bedrock edition load những file `material.bin` có trong resource pack, hoạt động tương tự như MaterialBinLoader hay Draco trên Android.

## Cách tinh chỉnh này hoạt động

Tinh chỉnh này hook hàm `fopen()` khi Minecraft gọi hàm này từ `libsystem_c.dylib` để chuyển hướng game sang load những file `material.bin` bên trong pack đã được active trong `Global Resource Packs` thay vì load những file gốc tương ứng.

## Cách sử dụng

Với thiết bị jailbreak, hãy tải tinh chỉnh này ở [đây](https://github.com/CyberGangzTeam/MaterialLoader/releases) và cài đặt nó thông qua sileo/zebra.

Với thiết bị không jailbreak (Jailed), hãy lấy file .dylib bên trong tinh chỉnh và inject trực tiếp nó vào file thực thi chính của ipa thông qua một số ứng dụng sideload như Esign, Ksign, Feather,etc... và cài đặt ipa đã được inject qua việc ký chứng chỉ hoặc cài qua TrollStore (nếu có).

## Third party

- [fishhook](https://github.com/jevinskie/fishhook): [BSD-3 License](https://github.com/facebook/fishhook/blob/main/LICENSE)