# DEVELOPMENT_LEDGER — Selective VPN Bypass

> **목적:** README는 사용자를 위한 현재 사용법만 설명하고, 이 파일은 개발 과정의 관측·결정·패치·실패·검증·회귀 위험을 시간순으로 남기는 **누적 개발 원장**이다.
>
> **시간 규칙:** 표기는 모두 한국 표준시(KST, UTC+09:00), `YYYY-MM-DD HH:mm:ss KST`. 시간이 분 단위로만 확인되면 `HH:mm KST (초 미확인)`으로 기록한다. 시각 미확인 사건에 임의 시각을 부여하지 않는다. GitHub 기록은 커밋 시각 기준이고, 사용자 관측은 실제 대화·명령 출력 기준이다.
>
> **신뢰성 규칙:** **OBSERVED**(사용자 환경에서 출력·스크린샷 확인), **COMMITTED**(GitHub 커밋 확인), **BUILT-LOCAL**(제작 환경에서 패키지 생성), **UNVERIFIED**(실기 검증 없음), **BLOCKED**(검증 불가), **PROPOSED**(예정)로 구별한다. 코드가 존재한다는 사실과 실제 Windows에서 기능이 정상이라는 주장은 다르다.
>
> **프라이버시:** 공용 문서에는 사용자의 로컬/학교 IP, 사설 네트워크 주소, VPN 서버 주소, 사용자별 예외 목록, 개인 계정 로그 등을 싣지 않는다. 테스트 IP는 모두 `<REDACTED>`로 취급한다. 실제 사례의 사이트명도 꼭 필요할 때만 대표성 있게 기술하며 사용자의 사적 예외 목록을 그대로 재현하지 않는다.
>
> **작성 권한:** 메인테이너 커밋은 `WhoSia` 계정에 귀속. GitHub Actions는 컴파일과 아티팩트 업로드만 담당하며 커밋, 태그, 자동 릴리스 작성 금지. 외부 기여자는 자신의 PR 커밋에 자신의 저자 표시를 유지한다.

---

## 2026-10-14 08:24 KST (초 미확인) — Windows + SoftEther 분할 라우팅의 초기 질문 [OBSERVED]

- 최초 문제: SoftEther VPN Gate 공개 서버에 연결한 Windows PC에서 도메인별로 VPN과 직접 인터넷 연결을 분리할 방법 탐색.
- Windows 라우팅은 목적지 **IP** 기준이다. 도메인 문자열 단독으로는 경로를 지정할 수 없다는 제약 확인.
- 정적 `/32` 경로, DNS 갱신, PAC/프록시, 인터페이스 기반 분리를 비교. PAC에는 별도 프록시가 필요하다는 한계를 확인.
- 최종 제품 요구는 이후 대화에서 **SoftEther를 기본 경로로 유지하면서 선택한 도메인·IPv4만 Wi-Fi로 직접 보내는 예외 관리 앱**으로 확정됨.
- **검증 수준:** 요구 분석. 프로그램 구현 성공을 뜻하지 않음.

## 2026-10-14 08:29~08:36 KST — 실제 라우팅 구조 관측 및 수동 구성의 실패 [OBSERVED]

- Windows PowerShell에서 Wi-Fi, VPN Gate 가상 어댑터, 별개 Tailscale 인터페이스 확인.
- VPN 가상 어댑터가 IPv4 기본 경로를 점유한 상태 확인. Wi-Fi에는 초기에 기본 경로가 없었고, DHCP/라우팅 자동 조정의 개입 가능성 존재.
- Wi-Fi 게이트웨이에 대한 ICMP 응답은 확인됐으나, Wi-Fi 기본 경로와 VPN 기본 경로를 조절하는 도중 **전체 기본 경로가 사라져 외부 TCP 접속에 실패**한 사건 발생.
- 이후 Wi-Fi 기본 경로를 재추가하여 인터넷을 복구. VPN이 여전히 작은 메트릭으로 기본 트래픽을 점유하는 구조 확인.
- 조치: VPN 기본 경로를 삭제하지 않고, 메트릭과 구체적인 목적지 경로를 별도 관리하는 방향으로 변경.
- **제품 영향:** 우선순위보다 먼저 복구 가능성과 변경 소유권 추적을 설계해야 함. Tailscale 경로는 변경 대상에서 제외.

## 2026-10-14 08:39 KST 전후 — 명령형 PowerShell 도구 도입 [OBSERVED / UNVERIFIED]

- 초기 `Selective-VPN-Bypass.ps1`는 `status/apply/restore`로 시작.
- PowerShell의 실행 정책이 서명되지 않은 스크립트 실행을 막았음. 해당 프로세스에 국한한 정책 변경으로 진단·실행 가능해짐.
- SoftEther 미연결 시 `apply`가 중단되는 동작 확인. 대상 인터페이스 상태를 변경 전 확인해야 함.
- 이후 `add/remove/list/dns` 추가, 도메인 목록의 JSON 저장, IPv4 입력 처리, GUI 실행기 제공.
- 초기 도구는 기존 사용자별 `/32` 경로를 소유권 없이 변경하지 않아, 충돌 시 `Skipped` 경고를 출력했음.
- **회귀 위험:** 명령이 성공 메시지를 출력해도 목적지 경로는 여전히 VPN일 수 있다.

## 2026-10-14 (시각 미확인) — 예외 IP와 DNS 응답의 분리 문제 확인 [OBSERVED]

- 특정 호스트에서 VPN ON일 때 HTTPS 403 응답, VPN OFF일 때 302 리디렉션을 관측.
- 최초 비교에는 `HEAD`/`GET`, DNS로 선택한 실제 원격 IP가 달라지는 교란 요인이 있었음. 이후 같은 원격 IP로 고정해 비교.
- VPN OFF에서 정상 응답한 원격 IP와 VPN ON 기본 DNS가 반환한 두 IP의 응답이 서로 달랐음.
- Wi-Fi DNS 서버와 VPN DNS 서버를 **각각 명시하여** 조회하자 서로 다른 A 레코드 집합을 반환함을 확인.
- `--resolve`만으로 연결 대상 IP를 바꾸더라도 Windows 경로 선택이 자동으로 Wi-Fi로 전환되는 것은 아님. `Find-NetRoute`로 VPN 기본 경로 사용을 확인.
- 결론: **DNS의 출처와 IP 라우팅은 별개다.** 예외 도메인의 DNS 조회·NRPT·Wi-Fi 경로가 일관돼야 함. 단, 서버측 403의 내부 차단 규칙은 외부에서 확정하지 못함.
- 초기 DNS 수집 로직이 DNS `Additional` 구역 주소까지 수집할 수 있던 결함 확인. 실제 `Answer` 섹션 및 질의 대상 이름 필터가 필요.

## 2026-10-14 (시각 미확인) — Windows GUI 시제품의 실패와 공개 배포 전환 [OBSERVED]

- Go 실행기가 PowerShell WinForms 화면을 띄우는 시제품 제작. PyQt 사용 아님.
- 실제 Windows 캡처에서 버튼/목록이 패널 뒤에 가려지는 Z-order 문제, DPI 스케일에 따른 흐림, 일부 입력 시 오류 발생 관측.
- 명시적인 오류: WinForms 개체의 `Enabled` 속성이 없다는 미처리 예외. 입력 변수로 PowerShell 자동 변수 `$input`을 사용한 설계 문제도 제기됨.
- 선택 삭제가 실제 사용자 환경에서 작동하지 않았고, 문구상 허용되는 도메인도 입력 거부 사례가 발생. 특정 TLD만 허용한다고 입증된 것은 아니지만 검증을 재설계할 필요가 있음.
- 가장 심각한 공개 배포 결함: 프로그램이 기존 개인 설정 JSON을 자동 발견하여 새 실행에서도 기존 예외 항목을 표시함.
- 조치 결정: 설치 직후 **기본 예외 목록 0개**, 이전 설정 **명시적 가져오기만 허용**, Windows 배율 100/125/150/200% 검증, Remove 선택 동작, 저장 후 재로드 회귀 테스트.
- **검증 수준:** 시제품 결함 실기 재현. 새 소스의 수정 효과는 아직 실기 검증 전.

## 2026-10-14 11:34:35 KST — GitHub 정본 초기화 [COMMITTED]

- 커밋 `6c3b1b0`: README 최초 작성.
- 레포: [WhoSia/Selective-VPN-Bypass](https://github.com/WhoSia/Selective-VPN-Bypass).
- 독립적인 개발 정본을 GitHub로 이동하는 첫 단계.
- 실행 가능한 전체 코드, 테스트, CI는 이 시점에 아직 갖추지 못함.

## 2026-10-14 12:30:58 KST — 초기 자동 빌드 워크플로 기록 [COMMITTED]

- 커밋 `7d4d927`: Windows portable ZIP 빌드 및 태그 릴리스 자동화 초안 작성.
- 이후 **자동 릴리스·봇 작성자 귀속 금지** 정책에 맞추어 초기 워크플로를 제거하고 다시 작성.
- GitHub의 `Code → Download ZIP`은 **소스 다운로드**이지 portable EXE가 아님. 실행용 ZIP은 Actions artifact 또는 메인테이너가 게시한 Release asset을 이용해야 함.

## 2026-10-14 12:36:15 KST — GUI 코드 재구성 [COMMITTED / UNVERIFIED]

- 커밋 `bd71db9`: `src/Gui.ps1` 추가.
- 표 형태의 레이아웃, 빈 상태의 예외 목록, 목록 선택·추가·삭제 버튼, SoftEther·Wi-Fi 상태 텍스트, Apply/Restore/Status/DNS 동작 연결.
- 흐린 글자와 레이아웃 파손을 줄이기 위한 DPI AutoScale 사용. **고해상도 네이티브 렌더링을 보장하는 수준은 아님**.
- 기존 사용자 설정을 기본값으로 다시 입력하지 않도록 코드 구성.
- **미검증:** 사용자 Windows에서 버튼 클릭·DPI·예외 처리 성공을 재현해야 함.

## 2026-10-14 12:36:59 KST — DNS/라우팅 백엔드 코드 추가 [COMMITTED / UNVERIFIED]

- 커밋 `1292bea`: `src/Core.ps1` 추가.
- 도메인과 IPv4 입력을 구별하고 JSON 목록 저장; 명시한 Wi-Fi DNS로 A 레코드 조회 후 IP 기반 경로 추가.
- 소유 상태 기록, NRPT 규칙 추가, 적용 시 기존 비소유 충돌을 확인하고 복구 작업을 시도하도록 설계.
- VPN 기본 경로·Tailscale은 의도적으로 수정하지 않는 정책 반영.
- **위험:** DNS 캐시, Windows NRPT 지원 방식, IPv6, 브라우저 DoH, 공유 CDN IP, DHCP 변경, 중간 장애 발생 시 롤백 누락 등을 Windows 실기에서 검증해야 함.

## 2026-10-14 12:37:35 KST — 자동 빌드 권한 제한 [COMMITTED / UNVERIFIED]

- 커밋 `d5248cd`: `.github/workflows/build-windows.yml` 새로 추가.
- 워크플로 권한 `contents: read`: Go 빌드 및 ZIP 아티팩트 생성만 수행.
- **금지:** Actions[bot]가 commit/push/tag/release를 작성하는 구성. 작성자 `WhoSia` 귀속이 보장되지 않으면 쓰기 자동화를 허용하지 않음.
- **검증 상태:** 워크플로 파일의 존재를 확인했지만, GitHub push 실행에 관한 독립적인 성공/실패 로그는 아직 확보하지 못함.

## 2026-10-14 12:38:24 KST — 다운로드·기여 안내 정합성 갱신 [COMMITTED]

- 커밋 `b2378b2`: README를 현재 아키텍처와 배포 정책에 맞게 수정.
- `main.go`, `go.mod`, `src/Gui.ps1`, `src/Core.ps1`, `src/Worker.ps1`, `CONTRIBUTING.md`, `LICENSE`, `.gitignore` 및 워크플로의 존재 확인.
- 메인테이너 커밋의 author/committer가 모두 `WhoSia`로 기록된 사례 확인.
- **정책:** MIT 오픈소스, 외부 참여는 PR로 허용하되 타인의 저자 표기를 임의로 `WhoSia`로 위장하지 않음.

## 2026-10-14 12:40 KST (초 미확인) — 개발 원장 제도화 및 Actions 결과 신고 [OBSERVED / BLOCKED]

- 사용자가 README 외에 Research OS형 **패치·검증 누적 원장**을 요청. 버전·세대별 명칭 대신 날짜·시각 단위의 사건 기록을 선택.
- 사용자가 “Actions 결과는 나왔다”고 보고함. **성공/실패 여부·실행 URL·로그·아티팩트 존재는 이 시점에 미제공**.
- GitHub 연결의 일반 상태 API에서는 검사 결과가 비어 있었고, PR 기반 조회에 한정된 Workflow Runs API에서도 해당 push 실행을 확인하지 못함. **결과 없음은 빌드 실패 또는 성공의 증거가 아니다.**
- 다음 확인 순서: Actions run URL/ID 확보 → Windows 빌드 job과 step 결과 확인 → ZIP artifact 목록·크기·SHA 확인 → 실제 Windows에서 빈 목록, 입력, 선택 삭제, DPI, Apply/Restore를 검증 → Preview Release 승인 여부 결정.
- 사용자 요구에 따라 메인테이너 측 변경 커밋은 `WhoSia` 계정으로만 수행.

---

---

## 2026-10-14 13:09~13:13 KST — CI 회귀 검증 체계 구축 및 WinForms DPI 초기화 보완 [COMMITTED / UNVERIFIED]

### 문제 배경
- 앞선 시제품에서 실제 관측된 화면 흐림, 컨트롤 미표시, 입력 삭제 실패, 개인 설정 자동 가져오기 등의 재발을 방지할 검증 게이트가 부족했다.
- 이전 자동 빌드는 소스 파싱·기초 동작 검증 없이 EXE·ZIP을 생성할 수 있는 구조였다. **빌드 성공만으로 실제 UI가 동작한다고 말할 수 없다.**
- 사용자는 Actions 결과가 생성됐다고 보고했으나, 현재 연결된 GitHub API가 제공하는 조회는 일반 push 실행의 상세 run 상태를 반환하지 않았다. **빌드 결과를 성공으로 추정하지 않는다.**

### 실제 수정과 GitHub 커밋
- [`ce695b3`](https://github.com/WhoSia/Selective-VPN-Bypass/commit/ce695b33ce763549a16732ca63fe2abff4b12773) — `tests/test-core.ps1` 신규 추가. Windows PowerShell 파서 검사, 빈 초기 목록, `.com/.kr/.wiki` 입력, 문서용 IPv4 입력, 대소문자 정규화, 중복 제거, JSON 지속성, 목록에서 한 항목만 삭제하기, URL·와일드카드·잘못된 IP 거부를 각각 검사. 테스트 데이터는 임시 디렉터리에만 저장하며 실제 네트워크 경로를 변경하지 않는다.
- [`68bc70d`](https://github.com/WhoSia/Selective-VPN-Bypass/commit/68bc70d9b927b38d4c193930f6526f33c1f821e9) — CI에 PowerShell 회귀 테스트 및 `go vet`, Go 컴파일·ZIP 존재·SHA-256 출력을 추가. `tests/**` 변경도 CI 트리거에 포함.
- [`419981f`](https://github.com/WhoSia/Selective-VPN-Bypass/commit/419981f87f40471d5b930d4bc081b00a9347a0a6) — WinForms 초기화 전에 Windows DPI awareness 컨텍스트 설정을 *시도*하도록 P/Invoke 추가. OS/호스트 정책상 설정 거부 시 GUI 기동 자체를 막지 않도록 실패 허용. **이것이 DPI 흐림 해소를 입증하지는 않는다.**
- [`6c2230d`](https://github.com/WhoSia/Selective-VPN-Bypass/commit/6c2230daa2caf6295b6fc5d49b124e8477c8d544) — `Gui.ps1`에 `-SmokeTest` 추가. 폼을 실제로 띄우지 않고 컨트롤 구성·빈 초기 목록을 검사하는 진입점. 자동화된 UI 초기화 검사와 실제 사용자 클릭·화면 렌더링 검사를 분리.
- [`052f810`](https://github.com/WhoSia/Selective-VPN-Bypass/commit/052f8104c876328ac7e20cbd70441585d8edee59) — Windows runner의 별도 단계에서 비대화형 WinForms 초기화 검사를 수행하고, 실패하면 후속 portable 빌드 단계로 진행하지 않도록 구성.

### 안전성·개방성
- GitHub Actions의 `permissions: contents: read` 유지. 자동 커밋·자동 태그·자동 릴리스 추가 없음.
- 커밋은 GitHub 연결의 `WhoSia` 계정으로 수행. 외부 기여자의 독립 저자 표기를 변경하지 않음.
- 기본 JSON에 사용자별 도메인·IP 설정을 하드코딩하지 않음. 테스트용 IPv4는 RFC 5737 문서 예제 대역을 사용.
- 시험은 관리자 권한이나 실제 SoftEther/학교 네트워크에 의존하지 않도록 분리.

### 검증 판정
- **COMMITTED:** 신규 회귀 테스트, GUI 초기화 스모크 테스트, 빌드 게이트, DPI 처리 코드.
- **LOCAL CHECK (LIMITED):** 제작 환경의 *이전 로컬 스냅샷*에서 Windows x64 PE 교차 컴파일은 성공했으나, 이 결과는 최신 GitHub HEAD에 대한 검증이 아니다.
- **UNVERIFIED:** 새 Actions 워크플로의 실제 PASS/FAIL, 출력 ZIP의 정확성, 사용자 Windows GUI DPI·입력·삭제 동작, 관리자 승인 및 Apply/Restore 복구.
- **NEXT:** 실행 URL 또는 run ID 확보 → Actions job/step 로그 조회 → 실패한 정확한 테스트만 수정 → 사용자 Windows에서 빈 설정·추가·선택 삭제·저장 재실행·해상도별 표시 확인 → 별도 승인 전까지 Preview Release 보류.

---

## 2026-10-14 13:12:12~13:13:36 KST — Windows Actions #10 최초 검증 확정 [CI PASS / FIELD UNVERIFIED]

- **검증 소스:** [Actions run #10](https://github.com/WhoSia/Selective-VPN-Bypass/actions/runs/38510172616), `main`의 커밋 `052f8104c876328ac7e20cbd70441585d8edee59`. 사용자 대화의 'Actions 결과가 나왔다'는 관측과 독립적으로 GitHub Run API, Job API, 실제 로그, Artifact API를 대조했다.
- **Run:** ID `38510172616`, job ID `115676624546`, 결론 `success`, 작성·트리거 사용자 `WhoSia`. Workflow 단계: checkout PASS, Go 설치 PASS, `tests/test-core.ps1` PASS, WinForms 초기화 SmokeTest PASS, `go vet`·Windows x64 컴파일 PASS, Artifact upload PASS.
- **테스트 로그에 실제 포함된 성공 문구:** `PowerShell syntax PASS.`; `Empty defaults, domain/IP add, case normalization, persistence, remove and rejection PASS.`; `GUI controls initialization PASS (no interactive display or DPI test).`
- **빌드 파일:** `SelectiveVPNBypass_GUI.exe` (Windows x64 PE), EXE와 README를 묶은 `SelectiveVPNBypass_Portable_Windows_x64.zip`. ZIP 내부 목록을 별도 다운로드 후 직접 점검했다.
- **Windows portable ZIP SHA-256:** `9d3d8bb75e731a8611eb46c3c321ea37e404c8477bea74c9b8e06acdacf9fd84`. Actions Artifact 래퍼 ZIP의 별도 SHA-256: `4daf3b0a12445a03fc57cc3931cac8486c91db4f37f16f0aa6ff886a15716829` (아티팩트 ID `11868954106`).
- **코드 작성자 귀속:** Source 커밋의 `author`/`committer`가 `WhoSia`임을 별도 확인. Runner의 `github-actions[bot]`는 새 소스 커밋을 수행하지 않았다. Workflow는 `permissions: contents: read` 유지.
- **판정:** **CI PASS / PE+ZIP VERIFIED.** 단, UI의 실제 시각적 선명도(100~200% DPI), 마우스 클릭 후 삭제 선택 동작, SoftEther 네트워크 `apply`/`restore`, DNS 정책 충돌, 실제 공인 출구 검증은 CI에서 수행되지 않았다. 이 범위를 **FIELD UNVERIFIED**로 유지.
- **동기화 기준:** Run #10 이후 수정은 README와 DEVELOPMENT_LEDGER 문서 커밋이며, 빌드에 임베드된 `main.go`, `src/*`, `go.mod`의 내용은 동일하다. 따라서 정본 소스와 배포 PE 내용 불일치로 표현하지 않는다.
- **다음 결정:** CI 아티팩트를 내려받을 수 있게 공개하되 안정성 전체를 단정하는 'production certified' 문구는 사용하지 않음. 추후 실기 검증 증거를 획득하면 새로운 시각 항목을 **추가**하여 판정한다.

## 2026-10-14 13:29:20~13:30:17 KST — 공개 portable ZIP 패키징 확정 [CI PASS / DISTRIBUTION VERIFIED / FIELD UNVERIFIED]

- 변경 동기: 직전 패키지에서 MIT 라이선스가 실행용 ZIP 내부에 누락됨. MIT 규정의 라이선스 포함 요건을 공개 배포에서도 준수하기 위해 워크플로 수정.
- [커밋 `d522d55`](https://github.com/WhoSia/Selective-VPN-Bypass/commit/d522d557b590d1e39fb1224fea06f44402ae30f4) — `.github/workflows/build-windows.yml`에 `LICENSE` 패키징 및 ZIP 내부의 EXE·README·LICENSE 존재 검사를 추가. 저장소 권한은 계속 `contents: read`로 유지.
- [Actions 실행 #38511636823](https://github.com/WhoSia/Selective-VPN-Bypass/actions/runs/38511636823): 전체 job `success`. PowerShell 회귀 테스트, WinForms 초기화 스모크 테스트, Windows x64 Go 컴파일, artifact 업로드가 모두 성공.
- Actions ZIP artifact ID `11869854276`, artifact 래퍼 SHA-256 `945e381ddcd9ffe10da202ca30f788c740632c5ec1f1e57fc27285c578168392`. artifact는 생성 시점에 만료되지 않은 상태.
- 실제 다운로드 후 2중 압축 아카이브를 검사하여 실행용 `SelectiveVPNBypass_Portable_Windows_x64.zip`을 추출. **배포용 ZIP SHA-256:** `a566965739f12c57f39f9b5f5a5c22b3a76854fabc772a4ce297df28046b2c1a`.
- 실행용 ZIP 실제 파일 목록: `SelectiveVPNBypass_GUI.exe` (1,789,952 bytes), `README.md` (3,733 bytes), `LICENSE` (1,084 bytes). 모든 압축 항목 무결성 검사 통과, EXE Windows PE32+ x86-64 GUI 형식 확인.
- 공개 배포 프라이버시 검사: 과거 개인 도메인·학교망 주소가 실행 파일에 평문 상수로 내장되지 않은 것을 대상 문자열별로 확인. 이 검사는 유출 가능성의 전체 보증이 아니라 알려진 개인 설정값에 대한 검사다.
- **판정:** GitHub 기반 자동 빌드 및 다운로드 가능한 ZIP 완성. **Windows 실기 GUI 가독성, Add/Remove 실제 클릭, Apply/Restore 후 네트워크 통신·복구는 아직 실기 증거 미확보.** 따라서 '전체 기능 production proven'이라고 서술하지 않는다.
- **배포 방식:** GitHub Actions artifact에서 portable ZIP 내려받기, 또는 확인된 동일 바이트의 아티팩트를 제공. Github Actions[bot]가 커밋·태그·릴리스를 발행하도록 구성하지 않는다.

## 2026-10-14 13:37~13:39 KST — GUI 두 번째 입력·Apply/Restore 먹통 수정 및 버튼 이벤트 반복 검증 [OBSERVED / CI PASS / FIELD HOLD]

### 재현 증상 및 원인
- 사용자 Windows에서 예외 목록에 첫 도메인을 추가한 뒤 두 번째 도메인/IP 추가가 되지 않고, Apply 뒤 작업이 멈추며 프로그램 재시작 후 Restore가 한 번 작동했다가 또 멈추는 현상이 보고되었다.
- 기존 `src/Gui.ps1`의 타이머 콜백은 `GetNewClosure()`를 사용하고 종료 후 `$script:running = $false`를 기록했다. 해당 콜백의 스크립트 범위가 본체와 달라질 수 있어 **본체가 읽는 실행 잠금 플래그가 해제되지 않을 위험**이 있었다.
- 장애 원인은 이 스코프 분리 문제가 가장 유력하지만 사용자의 이전 프로세스 메모리 덤프가 없어 단일 원인으로 단정하지 않는다.
- 테스트 결함: 과거 GUI 스모크 테스트는 컨트롤이 존재하는지만 검사했으며, 한 번 작동한 이후에도 입력·삭제·복구 버튼을 누를 수 있는지 검증하지 않았다.

### 패치
- [`789e151`](https://github.com/WhoSia/Selective-VPN-Bypass/commit/789e151b18bac75598eabe2429557d51770df4c7) — `src/Gui.ps1`에서 `GetNewClosure()` 제거. GUI 본체가 소유하는 단일 WinForms 타이머와 `$script:activeProcess`, `$script:activeLogPath`, `$script:activeAction`, `$script:running`으로 완료 여부를 추적하도록 변경. 완료·실패 시 자원 정리, 사용자 로그 표시, 목록·연결 상태 갱신. 오래 실행되는 작업 중에도 진행 시간을 표시.
- [`1cd09df`](https://github.com/WhoSia/Selective-VPN-Bypass/commit/1cd09dfbd11e4c2de32d5f399242c598f7abfcaf) — GitHub Actions에 WinForms 반복 동작 테스트를 신규 게이트로 추가. 오프라인 모의 워커로 Apply/Restore를 실행해 실제 VPN·라우팅은 변경하지 않음.
- [`c927c0e`](https://github.com/WhoSia/Selective-VPN-Bypass/commit/c927c0eb411b2c092dba8a318063faf4b62000c7) — 더 강한 UI 테스트: 실제 WinForms `Button.OnClick` 이벤트를 호출해 도메인·IPv4 4개 연속 추가, 선택된 항목만 삭제, Apply → Restore 3회 반복, 이후 도메인 재추가를 확인. 직접 `Run-Action`만 호출하는 종전 검사에서 벗어남.

### 자동화 검증 증거
- [Windows Actions 실행 #38512413831](https://github.com/WhoSia/Selective-VPN-Bypass/actions/runs/38512413831), source HEAD `c927c0eb411b2c092dba8a318063faf4b62000c7`, job ID `115683676095`.
- 원본 로그: `PowerShell syntax PASS.`, `GUI controls initialization PASS (no interactive display or DPI test).`, `GUI button-click regression PASS: multi-add, selected remove, 3 simulated apply/restore pairs, post-restore add.`
- 회귀 테스트, GUI 초기화, 반복 버튼 이벤트 검사, Go Windows x64 컴파일, ZIP 아티팩트 업로드 **모두 PASS**.
- [GitHub artifact ID `11870930913`](https://github.com/WhoSia/Selective-VPN-Bypass/actions/runs/38512413831): ZIP 래퍼 SHA-256 `6bc3d91cc03e48ce6fff05d675b7bfd0115548e4d3796711a06ba8edb2898c7d`.
- 추출된 **실행용 ZIP SHA-256:** `a86703a0bac8257f237c9a9f24196fdcea6ee67043c1efa58f3ceb6292fc2ef6`. 내부 `SelectiveVPNBypass_GUI.exe`, `README.md`, `LICENSE` 존재 및 ZIP CRC 검사 PASS.
- Source 커밋 author/committer `WhoSia`. Actions 워크플로는 여전히 `contents: read`, 봇 커밋 없음.

### 한계·잔여 위험
- 자동 검사는 Windows runner에서 **인터랙션 이벤트 및 비동기 잠금 해제**를 검증했으나, 실제 사용자 PC의 화면·DPI 선명도, UAC 승인, SoftEther 연결, Wi-Fi DNS 및 NRPT 적용, 실제 경로와 응답, 롤백 완결성을 검증하지 못했다.
- 사용자 PC의 이전 EXE에 저장된 예외 JSON과 관리 상태는 자동 삭제하지 않는다. 새 버전은 ZIP을 별도 폴더에 풀어 테스트한 뒤 설정을 필요한 경우에만 수동 이전하도록 안내.
- 이후 첫 실기 테스트: 빈 목록 → 도메인 두 개 순차 추가 → 단일 항목 삭제 → VPN ON Apply → Restore → 다시 Add·Apply. GUI가 유지되는지와 원장에 남길 민감 정보 없는 오류 메시지 확인.
- **판정:** 반복 조작 잠금 수정과 Windows CI 검증 PASS. 실제 SoftEther 네트워크 적용은 **FIELD HOLD**.

## 2026-10-14 13:41:35~13:42:33 KST — GUI 중복 클릭·실패 경로 복구 및 최종 Windows 빌드 재검증 [CI PASS / FIELD UNVERIFIED]

- **관측 근거:** 사용자는 기존 EXE에서 도메인/IP 한 개만 추가 가능한 현상, Apply 후 먹통, 프로그램 재시작 및 Restore 후 재잠금을 보고. 이전에 추가한 반복 버튼 검사가 성공했지만, 워커가 실패하거나 작업 도중 추가 버튼을 클릭하는 상황에 대한 검증이 부족했다.
- [WhoSia 커밋 `2f290ec`](https://github.com/WhoSia/Selective-VPN-Bypass/commit/2f290ec3f9ebd68b879f245d2171c4821edb7d7f): `src/Gui.ps1`에서 `Set-UiBusy`로 작업 중 Add/Remove/Apply/Restore/Status/DNS 버튼 비활성화, 비동기 작업 잠금해제 후 재활성화. 작업 도중 추가 시 텍스트를 무조건 지우지 않고 사용자가 입력한 내용을 보존. `Run-Action`이 작업 시작 여부를 Boolean으로 알려주도록 수정.
- 모의 워커에 실패 종료코드 `7` 경로를 추가하고, GUI가 실패를 `FAILED` 로그로 표시하며 작업 상태를 풀어 이후 새 도메인을 추가할 수 있는지 검사.
- Windows runner의 **실제 WinForms Button.OnClick 이벤트**를 사용해 다중 Add, 선택 Remove, Apply/Restore 3쌍 반복, 작업 중 추가 시도, 실패 후 재추가를 검사했다. 여기서 Apply/Restore는 **모의 워커**이므로 실제 VPN 경로 변경이 수행되지 않았다.
- [GitHub Actions 실행 `38512704727`](https://github.com/WhoSia/Selective-VPN-Bypass/actions/runs/38512704727), job `115684595541`: `success`; PowerShell 구문, 빈 목록, 도메인/IP 저장·삭제, GUI 초기화, 버튼 클릭·실패 복구, Go Windows x64 빌드, ZIP 업로드 전부 PASS.
- 원본 로그 근거: `GUI button-click regression PASS: multi-add, selected remove, 3 simulated apply/restore pairs, busy click, failed worker recovery, post-restore add.` (`2026-10-14 13:42:20 KST`)
- Actions 래퍼 artifact ID `11870107551`; 래퍼 SHA-256 `e8a237523ab7998fb1c422056f8ceaecbc156a2bbbbd5d588b53a27d279b8345`. 추출 후 Windows portable ZIP SHA-256: `c960f18fe5075d5730092ffed10e634060ff3a1880f50b7331a709633e067b59`.
- **배포물 직접 검증:** 내부 `SelectiveVPNBypass_GUI.exe` (PE32+ x64, 1,796,096 bytes), `README.md`, `LICENSE` 확인, ZIP CRC 검사 통과. ZIP은 사용자 환경 테스트를 요구하는 CI 검증 시제품이다.
- **귀속:** 코드 author/committer `WhoSia`; Actions에는 읽기 전용 권한만 유지하고 봇 커밋 생성하지 않음.
- **미해결:** 실제 SoftEther VPN 연결 중 `namu.wiki` 대상 DNS/NRPT/라우팅 적용 성공률, 관리자 UAC, DPI 표시 품질, Windows에서 실제로 클릭한 뒤 복구되는지 등은 현장 실행이 필요. 네트워크 변경 자체가 실패하면 이 패치는 오류를 명확히 보여줄 뿐 성공한 라우팅으로 만들지는 않는다.
- **다음 실기 회귀 조건:** 설정 JSON 백업 → 새 폴더에서 EXE 실행 → 도메인 2개 이상 추가 → 1개 삭제 → VPN 연결 후 Apply → Restore → 다시 Add/Apply → 각 단계 상태·경로·오류 확인. 문제가 나타나면 종료 전에 GUI 로그를 기록하되 공개 이슈에 실제 네트워크 주소를 올리지 말 것.

## 열린 검증 항목

| 항목 | 기준 | 현재 판정 |
| --- | --- | --- |
| GitHub Actions Windows Go 빌드 | run conclusion success + build step 성공 | **미확인** |
| Portable ZIP 아티팩트 | 지정 이름의 ZIP 제공, 압축 구조 및 실행기 포함 | **미확인** |
| 빈 초기 예외 목록 | 새 폴더 최초 실행 시 0개, 이전 Downloads 설정 미자동 탐색 | **코드 반영·실기 미검증** |
| 입력 검증 | `.kr`, `.wiki`, `.com`, 유효 IPv4, 거부 케이스 | **코드 반영·실기 미검증** |
| 선택 삭제 | 선택된 항목만 제거하고 JSON에 저장 및 화면 갱신 | **실기 미검증** |
| DPI | 100%, 125%, 150%, 200% 크기·텍스트 선명도·오버플로 없음 | **실기 미검증** |
| 상태·DNS | SoftEther/Wi-Fi 연결과 Wi-Fi DNS 결과 정확성 | **실기 미검증** |
| Apply | 목표 경로·NRPT·소유권을 검증하고 실패 시 원상 복구 | **실기 미검증** |
| Restore | 관리하는 경로만 제거하고 타 클라이언트 경로 유지 | **실기 미검증** |
| 첫 Preview Release | 위 검증 및 리스크 공지 후 WhoSia가 수동 배포 | **보류** |

## 이후 기록 템플릿

```markdown
## YYYY-MM-DD HH:mm:ss KST — 변경의 실제 내용 [OBSERVED / COMMITTED / ...]
- 동기 및 증상:
- 변경 전 상태(근거 링크):
- 수정한 파일/함수와 변경 요약:
- 근거가 되는 커밋:
- 실행/테스트 환경:
- PASS/FAIL/HOLD 및 재현 명령:
- 회귀 위험과 반례:
- 남은 문제 및 다음 검증:
```

**운영 원칙:** 실패를 성공으로 소급 표기하지 않는다. 구버전 오류는 삭제하지 않고 새 시각의 정정 항목을 추가한다. 필요 시 원장 길이에 따라 연도·월별 파일로 분할하되, 최초 정본은 이 파일을 유지한다.
