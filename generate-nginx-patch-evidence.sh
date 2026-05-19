#!/usr/bin/env bash
set -euo pipefail

IMAGE="${IMAGE:-renebakx/nginx-ingress-controller:1.14.5-p7}"
NGINX_VERSION="${NGINX_VERSION:-1.27.1}"
PLATFORMS="${PLATFORMS:-linux/amd64 linux/arm64}"
OUT_DIR="${OUT_DIR:-nginx-patch-evidence/$(date +%Y%m%d-%H%M%S)}"
MAX_FUZZ="${MAX_FUZZ:-2}"

CVE_PATCHES=(
  images/nginx/rootfs/patches/35_nginx-1.27.1-CVE-2026-40460.patch
  images/nginx/rootfs/patches/36_nginx-1.27.1-CVE-2026-40701.patch
  images/nginx/rootfs/patches/37_nginx-1.27.1-CVE-2026-42934.patch
  images/nginx/rootfs/patches/38_nginx-1.27.1-CVE-2026-42945.patch
  images/nginx/rootfs/patches/39_nginx-1.27.1-CVE-2026-42946.patch
)

mkdir -p "${OUT_DIR}"
OUT_DIR_ABS="$(cd "${OUT_DIR}" && pwd)"

if ! command -v docker >/dev/null 2>&1; then
  echo "docker is required" >&2
  exit 1
fi

{
  echo "image=${IMAGE}"
  echo "nginx_version=${NGINX_VERSION}"
  echo "generated_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "repo=$(git config --get remote.origin.url || true)"
  echo "git_commit=$(git rev-parse HEAD || true)"
  echo "git_describe=$(git describe --tags --always --dirty || true)"
  echo
  echo "cve_patches:"
  printf "  %s\n" "${CVE_PATCHES[@]}"
} > "${OUT_DIR}/summary.txt"

sha256sum "${CVE_PATCHES[@]}" > "${OUT_DIR}/cve-patch-files.sha256"

if [[ -n "${BUILD_LOG:-}" && -f "${BUILD_LOG}" ]]; then
  grep -E 'Patch: (35_nginx-1\.27\.1-CVE-2026-40460|36_nginx-1\.27\.1-CVE-2026-40701|37_nginx-1\.27\.1-CVE-2026-42934|38_nginx-1\.27\.1-CVE-2026-42945|39_nginx-1\.27\.1-CVE-2026-42946)' \
    "${BUILD_LOG}" > "${OUT_DIR}/build-log-cve-patch-lines.txt" || true
fi

docker buildx imagetools inspect "${IMAGE}" > "${OUT_DIR}/image-imagetools.txt" 2>&1 || true
docker image inspect "${IMAGE}" > "${OUT_DIR}/image-inspect-local.json" 2>&1 || true

for platform in ${PLATFORMS}; do
  safe_platform="${platform//\//-}"

  docker run --rm --platform "${platform}" --entrypoint /bin/bash "${IMAGE}" \
    -c '/usr/bin/nginx -V' \
    > "${OUT_DIR}/nginx-version-${safe_platform}.txt" 2>&1 || true

  docker run --rm --platform "${platform}" --user 0:0 --entrypoint /bin/bash "${IMAGE}" \
    -c 'sha256sum /usr/local/nginx/sbin/nginx /usr/bin/nginx /etc/nginx/modules/*.so /nginx-ingress-controller /dbg /wait-shutdown' \
    > "${OUT_DIR}/runtime-critical-files-${safe_platform}.sha256" 2>&1 || true
done

docker run --rm \
  -v "$PWD:/work:ro" \
  -v "${OUT_DIR_ABS}:/evidence" \
  -e NGINX_VERSION="${NGINX_VERSION}" \
  -e MAX_FUZZ="${MAX_FUZZ}" \
  registry.suse.com/bci/bci-base:16.0 \
  /bin/bash -euo pipefail -c '
    zypper addrepo -p 105 http://download.opensuse.org/distribution/leap/16.0/repo/oss/ download.opensuse.org-oss
    zypper --gpg-auto-import-keys refresh
    zypper install -y curl gzip tar patch findutils coreutils

    workdir="$(mktemp -d)"
    cd "${workdir}"
    curl -fsSLo "nginx-${NGINX_VERSION}.tar.gz" "https://nginx.org/download/nginx-${NGINX_VERSION}.tar.gz"
    sha256sum "nginx-${NGINX_VERSION}.tar.gz" > /evidence/upstream-nginx-tarball.sha256
    tar xzf "nginx-${NGINX_VERSION}.tar.gz"
    cd "nginx-${NGINX_VERSION}"

    overall_status=0

    : > /evidence/source-patch-apply.log
    for patch_name in $(ls /work/images/nginx/rootfs/patches); do
      echo "Patch: ${patch_name}" | tee -a /evidence/source-patch-apply.log
      if [[ "${patch_name}" == *.txt ]]; then
        if ! patch -p0 < "/work/images/nginx/rootfs/patches/${patch_name}" >> /evidence/source-patch-apply.log 2>&1; then
          echo "FATAL: patch -p0 failed for ${patch_name}" | tee -a /evidence/source-patch-apply.log >&2
          overall_status=1
        fi
      else
        if ! patch -p1 < "/work/images/nginx/rootfs/patches/${patch_name}" >> /evidence/source-patch-apply.log 2>&1; then
          echo "FATAL: patch -p1 failed for ${patch_name}" | tee -a /evidence/source-patch-apply.log >&2
          overall_status=1
        fi
      fi
    done

    # Strict apply-log checks: no FAILED hunks, no fuzz above the threshold,
    # no rejects, no whitespace fallback. These would all be silent successes
    # without an explicit guard.
    if grep -E "FAILED|REJECTED|Reversed \(or previously applied\)" /evidence/source-patch-apply.log >/dev/null; then
      echo "FATAL: source-patch-apply.log contains failed/rejected hunks" >&2
      overall_status=1
    fi
    high_fuzz=""
    while read -r _ n; do
      [[ -z "${n:-}" ]] && continue
      if (( n > MAX_FUZZ )); then
        high_fuzz+="fuzz ${n}"$'\n'
      fi
    done < <(grep -oE "fuzz [0-9]+" /evidence/source-patch-apply.log || true)
    if [[ -n "${high_fuzz}" ]]; then
      echo "FATAL: source-patch-apply.log contains fuzz greater than MAX_FUZZ=${MAX_FUZZ}:" >&2
      printf "%s" "${high_fuzz}" >&2
      overall_status=1
    fi

    : > /evidence/cve-reverse-dry-run.log
    cve_status=0
    for patch_path in \
      /work/images/nginx/rootfs/patches/35_nginx-1.27.1-CVE-2026-40460.patch \
      /work/images/nginx/rootfs/patches/36_nginx-1.27.1-CVE-2026-40701.patch \
      /work/images/nginx/rootfs/patches/37_nginx-1.27.1-CVE-2026-42934.patch \
      /work/images/nginx/rootfs/patches/38_nginx-1.27.1-CVE-2026-42945.patch \
      /work/images/nginx/rootfs/patches/39_nginx-1.27.1-CVE-2026-42946.patch
    do
      echo "Reverse dry-run: $(basename "${patch_path}")" | tee -a /evidence/cve-reverse-dry-run.log
      if patch -p1 -R --dry-run < "${patch_path}" >> /evidence/cve-reverse-dry-run.log 2>&1; then
        echo "RESULT: applied" | tee -a /evidence/cve-reverse-dry-run.log
      else
        echo "RESULT: not-applied" | tee -a /evidence/cve-reverse-dry-run.log
        cve_status=1
      fi
      echo >> /evidence/cve-reverse-dry-run.log
    done
    if [[ "${cve_status}" -ne 0 ]]; then overall_status=1; fi

    # Per-CVE marker assertions: each CVE has a known set of code markers that
    # must be present in the patched source with an expected minimum count. A
    # mismatch fails the proof even if patch returns success.
    declare -A cve_results
    check_marker() {
      local cve="$1"
      local min_count="$2"
      local pattern="$3"
      shift 3
      local files=("$@")
      local count
      count=$(grep -hE "${pattern}" "${files[@]}" 2>/dev/null | wc -l | tr -d "[:space:]")
      count=${count:-0}
      if [[ "${count}" -ge "${min_count}" ]]; then
        cve_results[${cve}_$(echo "${pattern}" | tr -c "[:alnum:]" "_")]="PASS (${count})"
      else
        cve_results[${cve}_$(echo "${pattern}" | tr -c "[:alnum:]" "_")]="FAIL (got ${count}, expected >=${min_count}): ${pattern}"
        overall_status=1
      fi
    }

    check_marker CVE-2026-40460 1 "ngx_quic_set_connection_path\\(c, path\\);" src/event/quic/ngx_event_quic_migration.c
    check_marker CVE-2026-40701 1 "ngx_resolver_ctx_t[[:space:]]+\\*resolve;"  src/event/ngx_event_openssl_stapling.c
    check_marker CVE-2026-40701 1 "ctx->resolve = resolve;"                    src/event/ngx_event_openssl_stapling.c
    check_marker CVE-2026-40701 1 "ctx->resolve = NULL;"                       src/event/ngx_event_openssl_stapling.c
    check_marker CVE-2026-42934 1 "ngx_min\\(NGX_UTF_LEN - ctx->saved_len"     src/http/modules/ngx_http_charset_filter_module.c
    check_marker CVE-2026-42934 1 "ctx->saved_len = len;"                      src/http/modules/ngx_http_charset_filter_module.c
    check_marker CVE-2026-42945 1 "e->is_args = 0;"                            src/http/ngx_http_script.c
    check_marker CVE-2026-42946 1 "r->state = 0;"                              src/http/modules/ngx_http_scgi_module.c src/http/modules/ngx_http_uwsgi_module.c
    check_marker CVE-2026-42946 1 "line_start"                                 src/http/ngx_http.h src/http/ngx_http_parse.c

    {
      echo "Per-CVE marker assertions (MAX_FUZZ=${MAX_FUZZ})"
      for k in "${!cve_results[@]}"; do
        echo "  ${k}: ${cve_results[$k]}"
      done
    } | sort > /evidence/patched-source-marker-assertions.txt

    # Keep the original free-form marker grep dump for human review.
    {
      echo "CVE-2026-40460"
      grep -n "ngx_quic_set_connection_path(c, path);" src/event/quic/ngx_event_quic_migration.c || true
      echo
      echo "CVE-2026-40701"
      grep -n "ngx_resolver_ctx_t          \\*resolve;" src/event/ngx_event_openssl_stapling.c || true
      grep -n "ctx->resolve = resolve;" src/event/ngx_event_openssl_stapling.c || true
      grep -n "ctx->resolve = NULL;" src/event/ngx_event_openssl_stapling.c || true
      echo
      echo "CVE-2026-42934"
      grep -n "ngx_min(NGX_UTF_LEN - ctx->saved_len" src/http/modules/ngx_http_charset_filter_module.c || true
      grep -n "ctx->saved_len = len;" src/http/modules/ngx_http_charset_filter_module.c || true
      echo
      echo "CVE-2026-42945"
      grep -n "e->is_args = 0;" src/http/ngx_http_script.c || true
      echo
      echo "CVE-2026-42946"
      grep -n "r->state = 0;" src/http/modules/ngx_http_scgi_module.c src/http/modules/ngx_http_uwsgi_module.c || true
      grep -n "line_start" src/http/ngx_http.h src/http/ngx_http_parse.c || true
    } > /evidence/patched-source-markers.txt

    # Fingerprint of the patched source files that the CVE patches touch.
    # This pins the post-patch state and makes any drift detectable.
    sha256sum \
      src/event/quic/ngx_event_quic_migration.c \
      src/event/ngx_event_openssl_stapling.c \
      src/http/modules/ngx_http_charset_filter_module.c \
      src/http/ngx_http_script.c \
      src/http/modules/ngx_http_scgi_module.c \
      src/http/modules/ngx_http_uwsgi_module.c \
      src/http/ngx_http.h \
      src/http/ngx_http_parse.c \
      > /evidence/patched-source-files.sha256

    if [[ "${overall_status}" -eq 0 ]]; then
      echo "PASS" > /evidence/verdict.txt
    else
      echo "FAIL" > /evidence/verdict.txt
    fi

    exit "${overall_status}"
  '

verdict="$(cat "${OUT_DIR}/verdict.txt" 2>/dev/null || echo "FAIL")"
echo "Patch-content verdict: ${verdict}"

# Optionally cross-reference a build log produced by build-patched-controller.
# If BUILD_LOG points at a real file, assert each CVE patch line appears.
if [[ -n "${BUILD_LOG:-}" && -f "${BUILD_LOG}" ]]; then
  echo "Cross-checking BUILD_LOG=${BUILD_LOG} for CVE patch application lines"
  build_log_status=0
  for p in 35_nginx-1.27.1-CVE-2026-40460.patch \
           36_nginx-1.27.1-CVE-2026-40701.patch \
           37_nginx-1.27.1-CVE-2026-42934.patch \
           38_nginx-1.27.1-CVE-2026-42945.patch \
           39_nginx-1.27.1-CVE-2026-42946.patch
  do
    if ! grep -q "Patch: ${p}" "${BUILD_LOG}"; then
      echo "  MISSING from build log: ${p}" >&2
      build_log_status=1
    else
      echo "  ok in build log: ${p}"
    fi
  done
  if [[ "${build_log_status}" -ne 0 ]]; then
    echo "FAIL: BUILD_LOG did not show every CVE patch being applied during the image build." >&2
    echo "FAIL (build-log cross-check)" > "${OUT_DIR}/build-log-verdict.txt"
    exit 1
  else
    echo "PASS" > "${OUT_DIR}/build-log-verdict.txt"
  fi
fi

cat <<EOF
Evidence written to: ${OUT_DIR}

Important files:
  ${OUT_DIR}/summary.txt
  ${OUT_DIR}/verdict.txt
  ${OUT_DIR}/image-imagetools.txt
  ${OUT_DIR}/nginx-version-*.txt
  ${OUT_DIR}/runtime-critical-files-*.sha256
  ${OUT_DIR}/cve-patch-files.sha256
  ${OUT_DIR}/upstream-nginx-tarball.sha256
  ${OUT_DIR}/source-patch-apply.log
  ${OUT_DIR}/cve-reverse-dry-run.log
  ${OUT_DIR}/patched-source-markers.txt
  ${OUT_DIR}/patched-source-marker-assertions.txt
  ${OUT_DIR}/patched-source-files.sha256
EOF
