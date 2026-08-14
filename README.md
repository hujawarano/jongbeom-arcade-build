# Jongbeom ARCADE Server Build

이 저장소는 공식 [`Robbbert/abcdefg`](https://github.com/Robbbert/abcdefg) ARCADE 최신 태그를 확인한 뒤,
Jongbeom 3단 WinUI 패치와 GCC16 호환 패치를 적용하고 GitHub Actions에서
`arcade64.exe`를 깨끗한 환경으로 빌드하는 서버용 저장소입니다.

## 자동 빌드 흐름

- 매일 03:17 KST에 최신 공식 태그 확인
- `main` 브랜치의 워크플로, 패처 또는 `PATCH_REVISION.txt`가 변경되면 실행
- Actions 화면에서 수동 실행 가능
- 공식 소스를 최신 태그로 매번 새로 clone한 뒤 두 검증된 패처를 순서대로 적용
- Windows/MSYS2에서 `make -j2` clean build 후 실행 파일 버전을 검증
- 같은 `source tag + PATCH_REVISION` Release가 이미 있으면 재빌드하지 않음
- 성공한 경우에만 GitHub Release로 `arcade64.exe`와 `jongbeom-release.json` 공개

## 안전 원칙

패치가 미래 ARCADE 소스 구조와 맞지 않으면 패처가 실패하고 Release는 생성되지 않습니다.
따라서 사용자의 현재 정상 `arcade64.exe`가 서버 빌드 실패 때문에 자동으로 망가지는 구조가 아닙니다.

이 저장소와 Release는 ROM, CHD 또는 cheat 파일을 저장하거나 배포하지 않습니다.

## PATCH_REVISION.txt

패치 내용이 바뀌어 같은 공식 ARCADE 버전을 다시 빌드해야 할 때 숫자를 1 증가시킵니다.
예를 들어 `jongbeom-tag289-r1`이 존재하는 상태에서 값을 `2`로 바꾸면
`jongbeom-tag289-r2`를 새로 빌드합니다.
