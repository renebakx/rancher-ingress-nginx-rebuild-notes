This repository does not contain a fork of Rancher ingress-nginx source code.
It documents a local rebuild of the public Rancher ingress-nginx tag v1.14.5-prime6.

## Source used:
https://github.com/rancher/ingress-nginx/tree/v1.14.5-prime6

## Build method:
The upstream GitHub Actions build logic was adapted to run locally.
No upstream source files were intentionally modified beyond applying patches already present 

## Changelog
- 18-05-26 Initial creation of this repository
- 19-05-26 Updated the build and evidence scripts to emit more proof of the applied patches. Build 1.14.5-p7 at Docker hub is the output of those scripts. No changes were made to the upstream code base.
- 27-05-26 Added the evidence 20260527-121116-build-1.14.5-p8, that release added 40_nginx-1.27.1-CVE-2026-9256.patch.
  
