{
  description = "TOTEM keyboard ZMK user config — syntax/lint devShell(固件构建走 GitHub Actions CI,本地不编译)。";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { nixpkgs, ... }:
    let
      # 与 wd-desktop / wd-pi 同款:只生成 Linux 系统(键盘固件目标全是 ARM/Cortex-M)。
      forAllSystems =
        fn:
        nixpkgs.lib.genAttrs nixpkgs.lib.platforms.linux (
          system: fn nixpkgs.legacyPackages.${system}
        );
    in
    {
      # 纯 lint shell(无编译产物)。mkShellNoCC:不拉 gcc —— 固件由 CI 跨编译,本地零 C 工具链。
      #
      # 覆盖仓内所有可 lint 的文本:
      #   dtc           — device tree 编译器,校验 .keymap / .overlay / .dtsi 的 DTS 语法。
      #                   ⚠️ 只做**语法级**校验:`#include <behaviors.dtsi>` 等头文件在 ZMK 主仓(经 west 拉取),
      #                   本仓没有 → dtc 无法解析 include,完整语义校验仍依赖 CI。dtc 适合裸 DTS 片段 / 引号 /
      #                   node 结构这类纯语法错误的即时检查。
      #   yamllint      — build.yaml / .github/workflows/*.yml / config/west.yml。
      #   markdownlint-cli2 — readme.md。
      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShellNoCC {
          packages = with pkgs; [
            dtc
            yamllint
            markdownlint-cli2
          ];
        };
      });
    };
}
