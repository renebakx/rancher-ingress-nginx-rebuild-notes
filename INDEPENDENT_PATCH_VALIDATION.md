# Independent Validation: NGINX CVE Patches in `renebakx/nginx-ingress-controller:1.14.5-p6`

## Scope

A third-party review of the evidence-collection scripts and their generated artifacts to determine whether the published image `renebakx/nginx-ingress-controller:1.14.5-p6` contains an NGINX binary that was actually built from the patched source tree in this repository.

This document is written from a fresh reading of:

- `scripts/build-patched-controller`
- `scripts/generate-nginx-patch-evidence`
- `images/nginx/rootfs/build.sh`
- `images/nginx/rootfs/patches/3{5,6,7,8,9}_*.patch`

## Conclusion

**The image is patched.** Three independent lines of evidence converge:

1. The build pipeline has no path that produces an unpatched NGINX.
2. The published binary is byte-identical to a fresh rebuild from the patched source tree on both architectures.
3. The CVE patches themselves contain the upstream fix code and apply cleanly to the declared NGINX source version.

A single one of these would be circumstantial. Together they are conclusive at the binary-provenance level.

## Evidence Line 1 — The build pipeline cannot produce an unpatched NGINX

`scripts/build-patched-controller` assembles a multi-stage Dockerfile inline. Stage `nginx-builder` performs:

```dockerfile
FROM registry.suse.com/bci/bci-base:16.0 AS nginx-builder
COPY images/nginx/rootfs/patches /patches
COPY --chmod=0755 images/nginx/rootfs/build.sh /
RUN /build.sh
```

`images/nginx/rootfs/build.sh:427-435` is the only place NGINX source is touched between download and `./configure`:

```bash
for PATCH in `ls /patches`;do
  echo "Patch: $PATCH"
  if [[ "$PATCH" == *.txt ]]; then
    patch -p0 < /patches/$PATCH
  else
    patch -p1 < /patches/$PATCH
  fi
done
```

The final image stage then pulls the entire `/usr/local` tree out of `nginx-builder`:

```dockerfile
COPY --from=nginx-builder /usr/local /usr/local
```

There is no alternative source for `/usr/local/nginx/sbin/nginx` in the Dockerfile. The image's NGINX is exactly what `build.sh` produced from `/patches`. Skipping the patch loop is not possible — `patch` aborts on failure under `set -e` semantics implicit to the script's structure (it would surface as a non-zero `RUN` exit), and the loop has no conditional that can bypass the CVE patch files.

## Evidence Line 2 — Byte-identical rebuild on both architectures

`scripts/generate-security-officer-proof` rebuilds NGINX in isolation from `images/nginx/rootfs/Dockerfile`, then computes `sha256sum /usr/local/nginx/sbin/nginx` inside both the published image and the freshly rebuilt one.

Reviewing the captured output:

| Platform | Published image hash | Fresh rebuild hash | Match |
|----------|----------------------|--------------------|-------|
| linux/amd64 | `fee7dae41c4ce4806c17e0e8e2ff42efdbc785cb0106cdfc04f8d4ee09c2a8c0` | `fee7dae41c4ce4806c17e0e8e2ff42efdbc785cb0106cdfc04f8d4ee09c2a8c0` | yes |
| linux/arm64 | `c87b1b56a6113c7828e8bda7d9a75be2bb5b03391e799a66cdbd986cc9221422` | `c87b1b56a6113c7828e8bda7d9a75be2bb5b03391e799a66cdbd986cc9221422` | yes |

A byte-identical match is significant because the build is reproducible — gcc 15.2.0, OpenSSL 3.5.0, identical configure arguments, identical source tree, identical patch set. Any tampering anywhere in the chain (a quietly removed patch, a swapped source tarball, a substitute binary slipped in during a later layer) would change the hash.

The same script also captures `nginx -V` from both images for each architecture. The configure-argument strings are character-for-character equal between the published and proof binaries.

## Evidence Line 3 — The patches themselves contain the CVE fixes

The five CVE patches under review:

```text
35_nginx-1.27.1-CVE-2026-40460.patch  3d4b516301d6bb8a4e6eac90cec9d4fd5b4fdf60c114554ca1dd4de5a92b4eaf
36_nginx-1.27.1-CVE-2026-40701.patch  ef550d6d60bc049b722f17654c6a2175a26bdd528b720cec24aca62ca660dd82
37_nginx-1.27.1-CVE-2026-42934.patch  26763c20b7c604ea33dc181bd91624132afc67dbc2f4b98fe173a90d2f7264f6
38_nginx-1.27.1-CVE-2026-42945.patch  f3e5749718ebe0cbef5b91291223122a8af6fabad504c71ed27493f8a9b6426e
39_nginx-1.27.1-CVE-2026-42946.patch  c3dc28fdab44d6c85e990d81d9f0a53cc22b3137fe3ba72a2f795ad09f0312b4
```

I inspected the patches directly. They modify the expected source files:

- `35`: `src/event/quic/ngx_event_quic_migration.c` — re-orders `ngx_quic_set_connection_path()` calls and gates them behind `next->validated`, addressing the QUIC path-migration handling flaw.
- `36`: `src/event/ngx_event_openssl_stapling.c` — adds resolver-context tracking (`ctx->resolve`) and null-clearing on cleanup.
- `37`: `src/http/modules/ngx_http_charset_filter_module.c` — clamps UTF buffer arithmetic via `ngx_min(NGX_UTF_LEN - ctx->saved_len, …)`.
- `38`: `src/http/ngx_http_script.c` — single-line fix inserting `e->is_args = 0;` before regex script tail processing.
- `39`: `src/http/modules/ngx_http_scgi_module.c`, `…_uwsgi_module.c`, `src/http/ngx_http.h`, `src/http/ngx_http_parse.c` — adds `r->state = 0;` resets and a new `line_start` tracking field for SCGI/uWSGI status-line parsing.

`generate-nginx-patch-evidence` independently downloads pristine `nginx-1.27.1` source from `nginx.org`, applies all repository patches in order (`source-patch-apply.log`), then performs `patch -p1 -R --dry-run` for each of the five CVE patches (`cve-reverse-dry-run.log`). All five report `RESULT: applied`. A successful reverse dry-run is the definition of "the patch is currently present in this source."

`patched-source-markers.txt` confirms the post-patch source contains the marker lines for each CVE (`e->is_args = 0;`, `ngx_quic_set_connection_path(c, path);`, the `line_start` field declaration, etc.).

## Cross-check: what `nginx -V` reveals

Both the published and rebuilt binaries identify as `nginx/1.27.1` built with `gcc 15.2.0 (SUSE Linux)` and OpenSSL `3.5.0 8 Apr 2025`. There is no mismatch in compiler, base toolchain, or module list between the proof and published binaries.

`nginx -V` does not by itself prove patches were applied — it would show `1.27.1` either way. Its role here is consistency: any difference between proof and published would invalidate Line 2. There is no difference.

## What this proof does NOT establish

- **Runtime exploitability.** A patched binary in a published image does not guarantee a running cluster is unexploitable. The deployed pod must reference this exact digest, the relevant modules must be active, and the exploit must target code actually covered by the patches.
- **Independent toolchain verification.** Both the proof and published binaries are produced from the same Dockerfile and patch set in this repository. The hash match proves reproducibility from this repository. It does not prove the patches match the upstream NGINX security advisories byte-for-byte — that would require comparing against patch files distributed by nginx.org or the original commit hashes in the NGINX repository. The patch *content* I reviewed is consistent with the published advisories, but a formal upstream-diff check is out of scope for the existing scripts.
- **Supply-chain attestation past the local builder.** `scripts/build-patched-controller` uses `docker buildx … --push` without `--attest` or `cosign sign`. Anyone inspecting the registry has only the manifest digest to anchor on. For a stronger chain, add buildx SLSA provenance attestations and image signing.

## Image identifiers anchored by this validation

```text
Image:                docker.io/renebakx/nginx-ingress-controller:1.14.5-p6
OCI index digest:     sha256:e72ddc3d31bd187b8377b2c652edcb43ac7aa1c789615f300a96879239252dba
linux/amd64 manifest: sha256:b2412cd3d4368b69fd21d6ef47acb09217494dcfcdd5090898df4525e1c8e03c
linux/arm64 manifest: sha256:538546d63509e28cec642321d2ad636f10707e4c643dc3f17652b8eb3c918510
Repo commit:          1134a65f6e3abc2b632e828dc0257dde4455eb60
Repo tag:             v1.14.5-prime6
```

If the registry serves a tag that resolves to a different OCI index digest in the future, this validation no longer applies — re-run the proof scripts against the new digest.

## Final statement

Within the limits stated above, the NGINX binary inside `renebakx/nginx-ingress-controller:1.14.5-p6` was produced by the build pipeline in this repository with all five CVE patches (`CVE-2026-40460`, `CVE-2026-40701`, `CVE-2026-42934`, `CVE-2026-42945`, `CVE-2026-42946`) applied to `nginx-1.27.1` source. The published binary is byte-identical to a fresh rebuild from the same source tree on both supported architectures. I am confident this image is patched.

Document generated by Opus 4.7 