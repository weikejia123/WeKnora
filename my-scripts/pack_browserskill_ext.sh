#!/usr/bin/env bash
# pack_browserskill_ext.sh —— 取出/构建 WeKnora 配套的 BrowserSkill 浏览器扩展，解压为可直接加载的目录
#
# 用法:
#   ./pack_browserskill_ext.sh               # 默认: 从 111 的 WeKnora-app 容器取现成 ZIP（推荐，保证与 daemon 匹配）
#   ./pack_browserskill_ext.sh --build       # 从源码按 pinned commit 构建（需 pnpm/cargo，慢）
#   ./pack_browserskill_ext.sh --build ext   # 只构建扩展部分
#
# 输出: my-other-git/browser-skill-weknora-<版本>/  （Chrome「加载已解压的扩展程序」选此目录）
#       my-other-git/browser-skill-weknora-<版本>.zip
#
# 注意: 扩展版本必须与服务端 bsk daemon 基线一致；服务端升级后请重跑本脚本。
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out_base="${repo_root}/my-other-git"
ssh_host="nanning-111"          # ssh config 别名（111 部署机）
app_container="WeKnora-app"     # 111 上的 app 容器名
remote_zip="/opt/weknora/browserskill"

mode="fetch"
target="all"
case "${1:-}" in
  "") ;;
  --build) mode="build"; target="${2:-all}" ;;
  *) echo "未知参数: $1（支持: 无 / --build [all|ext]）" >&2; exit 2 ;;
esac

pin_json="${repo_root}/scripts/browserskill-release.json"
pin_version="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['extension']['version'])" "${pin_json}")"
pin_commit="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['extension']['source_commit'])" "${pin_json}")"

# ---- fetch 模式: 从 111 容器取现成 ZIP ------------------------------------
fetch_from_111() {
  echo "==> 从 ${ssh_host}:${app_container} 取扩展 ZIP（pinned 版本 ${pin_version}）..."
  local zip_name="browser-skill-weknora-${pin_version}.zip"
  ssh "${ssh_host}" "docker cp ${app_container}:${remote_zip}/${zip_name} /tmp/${zip_name}"
  scp -q "${ssh_host}:/tmp/${zip_name}" "${out_base}/${zip_name}"
  ssh "${ssh_host}" "rm -f /tmp/${zip_name}"
  echo "==> 解压..."
  rm -rf "${out_base}/browser-skill-weknora-${pin_version}"
  ditto -x -k "${out_base}/${zip_name}" "${out_base}/browser-skill-weknora-${pin_version}"
}

# ---- build 模式: 本地从源码构建 -------------------------------------------
build_from_source() {
  echo "==> 从源码构建（commit ${pin_commit}）..."
  command -v npx >/dev/null || { echo "需要 Node/npx" >&2; exit 1; }
  local build_dir; build_dir="$(mktemp -d /tmp/weknora-bsk-build.XXXXXX)"
  trap 'rm -rf "${build_dir}"' EXIT
  git clone --no-checkout https://github.com/Tencent/BrowserSkill.git "${build_dir}/source"
  git -C "${build_dir}/source" checkout --detach "${pin_commit}"
  ( cd "${build_dir}/source" && npx --yes pnpm@10.17.0 install --frozen-lockfile && npx --yes pnpm@10.17.0 ext:build:zip )
  local zip_name="browser-skill-weknora-${pin_version}.zip"
  cp "${build_dir}/source/apps/extension/dist/browser-skillextension-${pin_version}-chrome.zip" "${out_base}/${zip_name}"
  rm -rf "${out_base}/browser-skill-weknora-${pin_version}"
  ditto -x -k "${out_base}/${zip_name}" "${out_base}/browser-skill-weknora-${pin_version}"
  if [ "${target}" = "all" ]; then
    echo "==> daemon 构建请用: scripts/build_browserskill.sh（app 镜像构建时自动做，本脚本不重复）"
  fi
}

if [ "${mode}" = "fetch" ]; then
  fetch_from_111
else
  build_from_source
fi

echo ""
echo "完成。Chrome「加载已解压的扩展程序」选择目录："
echo "  ${out_base}/browser-skill-weknora-${pin_version}"
echo "（目录根下应有 manifest.json；扩展升级后需在 chrome://extensions 点刷新或重新加载）"
