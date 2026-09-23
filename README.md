# Tapmix

macOS 앱별 음량 조절기 (SoundSource 스타일). Core Audio **Process Tap** API 기반이라
커널 익스텐션이나 가상 오디오 드라이버 없이 동작한다.

- 요구사항: macOS 15+ (Swift 네이티브 `AudioHardwareSystem` API), Xcode 16+
- 현재 상태: **마일스톤 4** — 출력 장치 선택, 시스템 볼륨, 앱별 볼륨/음소거/레벨미터

## 실행

```bash
open Tapmix.xcodeproj
```

Xcode 에서 ⌘R. 메뉴바에 스피커 아이콘이 뜬다. 첫 실행 시 "시스템 오디오 녹음" 권한
요청이 뜨는데, 허용해야 앱별 볼륨이 동작한다.
(시스템 설정 › 개인정보 보호 및 보안 › 화면 및 시스템 오디오 녹음)

보기 방식 (SoundSource 처럼):
- 메뉴바 팝오버 (기본)
- 팝오버 우상단 창 아이콘 → 독립 창으로 떼어냄. 기본으로 항상 위에 뜬다.
- 톱니바퀴 메뉴: Dock 아이콘 표시 / 창 항상 위 / 시작 시 창 열기

디버깅: 앱이 `com.yu.Tapmix` 서브시스템으로 os_log 를 남긴다.

```bash
log stream --predicate 'subsystem == "com.yu.Tapmix"' --style compact
```

권한 상태, 앱 목록, 탭 생성/실패, 탭 포맷, (DEBUG) 2초마다 재생 중인 앱의 레벨이 찍힌다.
ad-hoc 서명이라 **재빌드할 때마다 TCC 권한을 다시 물어볼 수 있다** — 정상이다.

CLI 빌드:

```bash
xcodebuild -project Tapmix.xcodeproj -target Tapmix -configuration Debug build
```

## 구조

```
Tapmix/
  TapmixApp.swift          MenuBarExtra + Window 씬
  AppPresentation.swift          창/Dock 표시 설정, activation policy 전환
  Audio/
    AudioProcessMonitor.swift    프로세스를 앱 단위로 그룹핑, 탭 생명주기, 볼륨/음소거, 설정 저장
    ProcessTap.swift             탭(.muted) + aggregate device + IOProc: gain 곱해서 재생, 피크 측정
    OutputDeviceController.swift 출력 장치 목록/선택, 시스템 볼륨('vmvc'), 음소거
    AudioCapturePermission.swift TCC 오디오 캡처 권한 preflight/request (dlsym)
    PropertyListener.swift       AudioObject 프로퍼티 변경 알림 래퍼
  UI/
    MainPopoverView.swift        전체 팝오버/창 (출력 섹션 / 앱 목록 / 권한 배너 / 설정 메뉴)
    OutputSectionView.swift      장치 피커 + 시스템 볼륨 슬라이더
    AppRowView.swift             앱 한 줄: 아이콘, 이름, 미터, 음소거, 슬라이더
    LevelMeterView.swift         가로 레벨미터 (dB 스케일 표시)
Config/
  Info.plist                     LSUIElement, NSAudioCaptureUsageDescription
```

동작 원리:

1. `AudioHardwareSystem.shared.processes` 로 Core Audio 에 등록된 프로세스를 얻고,
   `responsibility_get_pid_responsible_for_pid` 로 헬퍼 프로세스(Safari 의 WebKit.GPU 등)를
   부모 앱 pid 로 묶는다. Dock 에 뜨는 앱이거나 지금 소리를 내는 것만 보여준다.
2. 앱마다 `CATapDescription(stereoMixdownOfProcesses:)` 를 `.muted` 로 만들어
   원래 출력을 끊고, 탭을 입력으로 갖는 private aggregate device 에 IOProc 를 건다.
3. IOProc(실시간 스레드)가 입력 × gain 을 출력에 쓴다 (`vDSP_vrampmul`, 버퍼 내 램프로
   클릭음 방지). 볼륨/음소거는 `TapControl.gain` 하나로 처리. 피크는 `Atomic<Float>` 로
   메인 스레드에 전달해 30Hz 로 미터를 그린다.
4. 앱별 설정은 bundle ID 키로 UserDefaults 에 저장되어 재시작 후에도 유지된다.
5. 기본 출력 장치가 바뀌면 aggregate 가 옛 장치에 묶여 있으므로 모든 탭을 다시 만든다.

권한: 오디오 캡처 TCC 권한이 없으면 `.muted` 탭이 앱을 그냥 무음으로 만들기 때문에,
`AudioCapturePermission.status == .granted` 일 때만 탭을 만든다.

## 알려진 한계 / 다음 단계

- 탭 → 재생 경로 때문에 버퍼(256 프레임 ≈ 5ms) 만큼 지연이 추가된다.
- Apple Music/Netflix 등 DRM 오디오는 탭이 무음으로 나올 수 있다.
- 앱별 출력 장치 라우팅: aggregate 의 main sub device 를 앱마다 다르게 주면 된다.
- 앱별 EQ: IOProc 안에 `vDSP_biquad` 를 끼우면 된다.
- macOS 26+ 에서는 `CATapDescription.bundleIDs` + `processRestoreEnabled` 로
  아직 안 켜진 앱도 미리 등록할 수 있다.
- 100% 이상 부스트가 필요하면 슬라이더 범위를 늘리고 클리핑 처리를 추가.

## 실시간 스레드 규칙

`ProcessTap` 의 IOProc 블록 안에서는 절대로: 메모리 할당, 락, ObjC 메시지, 로깅,
Swift 클래스 인스턴스 생성을 하지 않는다. `self` 도 캡처하지 않는다 (`LevelStore` 만).

## 라이선스

Copyright (C) 2026 Luca388

[GNU General Public License v3.0](LICENSE) 으로 배포된다. 이 코드를 수정하거나 포함한
프로그램을 배포하려면 그 소스도 같은 GPL-3.0 으로 공개해야 한다.
