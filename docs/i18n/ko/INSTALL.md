# 설치·서명 갱신·업데이트

**기기 변경:** 시스템 이전만으로 앱과 라이브러리 복원을 보장할 수 없습니다. 기존 앱과 데이터를 보관하세요. [이전 및 실행 문제 해결](../../MIGRATION.md)

[简体中文](../../INSTALL.md) · [繁體中文](../zh-Hant/INSTALL.md) · [English](../en/INSTALL.md) · [日本語](../ja/INSTALL.md) · **한국어**

**[안정판 IPA 다운로드](https://github.com/Reyanna0o0/Simo-soundplayer/releases/download/v0.1.4/simo-0.1.4-build37-unsigned.ipa) · [베타판 IPA 다운로드](https://github.com/Reyanna0o0/Simo-soundplayer/releases/download/v0.1.5-beta.1/simo-0.1.5-build38-unsigned.ipa)** · [다운로드 버전 선택](DOWNLOAD.md)

[다운로드 페이지](DOWNLOAD.md)에서 안정판 v0.1.4(build 37) 또는 베타판 v0.1.5(build 38)를 선택하세요. 같은 Apple 계정, 서명 설정과 앱 식별자로 업데이트하고 **기존 앱을 먼저 삭제하지 마세요**.

두 파일 모두 서명되지 않은 IPA이므로 직접 서명해야 합니다. 같은 앱의 두 릴리스 중 하나를 선택할 수 있습니다.

**베타판은 테스트 버전입니다. 백업 복원은 현재 라이브러리 전체를 교체하며, 병합하지 않습니다. 실제 기기에서의 전체 복원과 가정용 NAS 사용은 아직 인수 검증을 마치지 않았습니다.** 중요한 원본 파일과 기존 앱을 보관하세요. [베타판 지원 범위와 제한 — 중국어 간체](../../RELEASE_BUILD38.md)

처음 설치한다면 아래 준비부터 시작하세요. 이미 설치했다면 [데이터를 유지하며 업데이트](#update)로 이동하세요.

Mac + Sideloadly 설치와 build 33 덮어쓰기 업데이트는 실측 기록이 있습니다. Windows, AltStore와 서명 갱신은 아직 검증하지 않았습니다. [버전 안내](../../RELEASE_BUILD37.md) · [상세 검증 기록 — 중국어 간체](../../RELEASE_STATUS.md)

## 준비할 것

- iOS / iPadOS 18 이상의 iPhone 또는 iPad, Windows PC 또는 Mac, 처음 연결할 때 사용할 케이블.
- 자신의 Apple 계정과 다운로드한 `.ipa` 파일.

무료 계정의 개발용 서명은 일반적으로 7일간 유효하며, 이 방식으로 기기에 동시에 설치할 수 있는 앱은 보통 3개입니다. App ID 등 다른 제한도 있으므로 Apple과 서명 도구의 안내를 따라 주세요. 만료 시에는 앱을 유지한 상태로 다시 서명합니다. [Apple 계정 안내](https://developer.apple.com/help/account/basics/about-your-developer-account/) · [Sideloadly FAQ](https://sideloadly.io/faq.html)

Apple 계정 로그인은 서명 도구에서 진행합니다. Simo 자체는 Apple 계정 로그인을 요구하지 않으며 비밀번호, 인증 코드나 서명 인증서를 수집하지 않습니다.

<a id="sideloadly"></a>
## 방법 1: Sideloadly (Windows / Mac)

1. [Sideloadly 공식 사이트](https://sideloadly.io/index.html)에서 운영체제에 맞는 버전을 받습니다. Windows의 Apple 드라이버와 iTunes / iCloud 구성요소, Mac의 준비 사항은 현재 공식 안내를 따라 주세요. 지원하지 않는다고 명시된 구성요소를 섞어 사용하지 마세요.
2. 케이블로 기기를 연결하고 잠금을 해제한 뒤 「이 컴퓨터를 신뢰하겠습니까?」에서 신뢰를 선택합니다. Sideloadly에서 기기를 선택합니다.
3. IPA를 Sideloadly로 드래그하고 자신의 Apple 계정을 입력합니다. 첫 설치는 기본 설정을 사용하며 플러그인을 추가하거나 앱 식별자를 바꾸지 마세요.
4. **Start**를 누르고 계정 인증 안내를 따른 뒤 서명과 설치가 끝날 때까지 기다립니다.
5. 신뢰하지 않는 개발자 안내가 나오면 「설정 → 일반 → VPN 및 기기 관리」에서 자신의 개발자 계정을 신뢰합니다. 개발자 모드가 필요하면 「설정 → 개인정보 보호 및 보안 → 개발자 모드」를 켜고 안내에 따라 재시동 후 다시 확인합니다. [Apple 개발자 모드 안내](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device)
6. Simo를 열고 다시 구할 수 있는 오디오로 가져오기, 재생, 백그라운드 재생과 앱 재실행을 확인한 뒤 주요 소장 자료를 가져오세요.

메뉴 이름은 도구와 OS 버전에 따라 달라질 수 있습니다. 차이가 있으면 현재 공식 안내를 참조하세요.

### 서명 갱신

동일한 Apple 계정, 앱 식별자와 서명 설정을 유지하세요. 만료 전에 같은 IPA를 다시 서명해 기존 앱 위에 설치합니다. 자동 갱신에는 컴퓨터에서 Sideloadly Daemon이 실행 중이어야 하며, USB 또는 설정된 동일 Wi-Fi로 기기를 찾을 수 있어야 합니다. 컴퓨터가 꺼져 있으면 자동 갱신에 의존할 수 없습니다. [자동 갱신 안내](https://sideloadly.io/faq.html)

## 방법 2: AltStore Classic

공식 [Windows 안내](https://faq.altstore.io/altstore-classic/how-to-install-altstore-windows) 또는 [Mac 안내](https://faq.altstore.io/altstore-classic/how-to-install-altstore-macos)에 따라 AltServer를 설치하고, 기기에 AltStore Classic을 설치합니다. 여기서는 Classic의 직접 서명 방식을 사용합니다.

기기에서 IPA를 받은 뒤 AltStore의 **My Apps → +**로 파일을 선택해 서명하고 설치합니다. 갱신할 때는 AltServer가 켜져 있고 기기에서 연결할 수 있어야 합니다. 필요하면 **Refresh All**을 누르세요. 무료 계정에서 AltStore 자체도 앱 설치 한 자리를 사용합니다. [AltStore 사용 안내](https://faq.altstore.io/altstore-classic/your-altstore)

<a id="update"></a>
## 데이터를 유지하며 업데이트

2026년 11월 23일, 사용자는 build 33 업데이트가 성공했으며 이전에 가져온 데이터가 남아 있음을 확인했습니다. 해당 결과는 당시 설치 환경에 한정되며, 서명 갱신과 다른 환경은 아직 검증하지 않았습니다.

새 IPA를 받아 **같은 Apple 계정·서명 도구·앱 식별자**로 기존 앱 위에 설치하세요. **먼저 삭제하지 마세요.** 같은 식별자는 덮어쓰기의 전제이며, 자신의 설치 환경에서 데이터가 유지되는지도 확인해야 합니다. [Sideloadly 업데이트 안내](https://sideloadly.io/faq.html)

- 서명이 만료되거나 설치가 실패하면 기존 앱을 남겨 두고 오류, 계정 제한과 연결 상태를 확인하세요.
- 계정, Team 또는 앱 식별자가 바뀌면 별도 앱이 생기거나 덮어쓸 수 없을 수 있습니다. 데이터가 자동으로 옮겨진다고 가정하지 마세요.
- 원본 오디오·동영상·자막은 따로 보관하세요. 중요한 클립은 MP3 / WAV로 내보낼 수 있습니다. 안정판 v0.1.4에는 전체 라이브러리 백업·복원 메뉴가 없습니다. 베타판 v0.1.5는 설정에 이 메뉴를 추가했지만, 복원은 **전체 라이브러리를 교체하며 병합하지 않습니다**. 실제 기기에서의 전체 복원은 아직 검증하지 않았습니다. [베타판 안내 — 중국어 간체](../../RELEASE_BUILD38.md)
- 폴더로 가져온 작품은 원래 위치를 참조합니다. 파일을 옮기면 작품 메뉴에서 다시 연결하세요. 재설치는 다시 연결을 대신하지 않습니다.

## 자주 생기는 문제

| 상황 | 해결 방법 |
| --- | --- |
| Safari에서 다운로드했지만 설치할 수 없음 | IPA를 위의 서명 도구에 넣어 주세요 |
| 며칠 뒤 앱이 열리지 않음 | 서명 만료를 확인하고 앱을 유지한 채 원래 계정으로 갱신하세요 |
| 기기 또는 App ID 개수 제한 | 도구의 안내를 확인하고 한도 회복을 기다리거나 설치된 테스트 앱을 정리하세요 |
| 컴퓨터가 기기를 찾지 못함 | 케이블, 잠금 해제, 컴퓨터 신뢰와 Apple 드라이버를 확인하세요 |
| 업데이트 후 Simo가 두 개 생김 | 계정이나 식별자가 바뀌었는지 확인하고 원래 앱과 데이터를 보존하세요 |
| 개발자 모드가 보이지 않음 | Apple의 연결·개발 서명 설치 절차 후 다시 확인하고 OS와 표시 메시지를 기록하세요 |

<a id="verify"></a>
## 선택 사항: 다운로드 파일 검증

같은 버전의 `.ipa.sha256`을 IPA 옆에 저장하고 그 폴더에서 터미널 또는 PowerShell을 여세요. 아래는 build 37 기준이며, 다른 버전은 실제 파일명으로 바꿔야 합니다.

Mac:

```bash
shasum -a 256 -c simo-0.1.4-build37-unsigned.ipa.sha256
```

`OK`가 나오면 일치합니다. `FAILED`라면 같은 버전에서 두 파일을 다시 받으세요.

Windows PowerShell:

```powershell
Get-FileHash .\simo-0.1.4-build37-unsigned.ipa -Algorithm SHA256
```

텍스트 편집기로 `.sha256`을 열고 첫 문자열을 `Hash`와 비교합니다. 영문 대소문자를 제외한 모든 문자가 같아야 합니다.
