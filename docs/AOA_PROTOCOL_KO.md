# Android Open Accessory (AOA) 프로토콜 - Andmon 구현 상세

이 문서는 macOS 호스트와 Android 수신기 사이의 고속, 저지연 통신 채널을 구축하기 위해 Andmon에서 사용하는 Android Open Accessory (AOA) 프로토콜 구현에 대해 설명합니다.

## 1. AOA 식별 및 핸드셰이크

통신을 시작하기 위해 macOS 호스트는 연결된 Android 기기를 식별하고 핸드셰이크를 수행하여 기기를 액세서리 모드(Accessory Mode)로 전환합니다.

### 1.1 USB 제어 전송 (Control Transfers)

호스트는 표준 AOA 제어 요청(공급자 정의 값을 가진 표준 USB 요청)을 사용합니다:

1.  **프로토콜 확인 (Request 51)**: 기기가 Android Accessory Protocol을 지원하는지 확인합니다.
    *   `bmRequestType`: `0xC0` (Device-to-Host, Vendor, Device)
    *   `bRequest`: `51`
    *   `wValue`: `0`
    *   `wIndex`: `0`
    *   `wLength`: `2`
    *   반환값: 프로토콜 버전 (1 이상이어야 함).

2.  **식별 문자열 전송 (Request 52)**: 기기에 식별 문자열을 보냅니다.
    *   `bmRequestType`: `0x40` (Host-to-Device, Vendor, Device)
    *   `bRequest`: `52`
    *   `wValue`: `0`
    *   `wIndex`: 문자열 인덱스 (0 ~ 5)
    *   `wLength`: 문자열 길이 + 1 (null 포함)
    *   `data`: 식별 문자열 내용.

3.  **액세서리 시작 (Request 53)**: 기기가 액세서리 모드로 재시작하도록 요청합니다.
    *   `bmRequestType`: `0x40` (Host-to-Device, Vendor, Device)
    *   `bRequest`: `53`
    *   `wValue`: `0`
    *   `wIndex`: `0`
    *   `wLength`: `0`

### 1.2 식별 문자열 (Identification Strings)

Andmon은 다음 식별 문자열을 사용합니다 (`LibUSBBridge.m` 및 `PROTOCOL.md`에 정의됨):

| 인덱스 | 필드 | 값 |
| :--- | :--- | :--- |
| 0 | Manufacturer | `Andmon` |
| 1 | Model | `Galaxy Tab S8 Ultra Submonitor` |
| 2 | Description | `Wired extended desktop receiver` |
| 3 | Version | `1.0` |
| 4 | URI | `https://localhost/andmon` |
| 5 | Serial Number | `andmon-mvp` |

---

## 2. 와이어 프로토콜 (Wire Protocol)

기기가 액세서리 모드로 전환되면, 벌크(Bulk) IN/OUT 엔드포인트를 통해 통신이 이루어집니다. 모든 메시지는 24바이트 빅엔디안(Big-endian) 헤더와 선택적 페이로드로 구성됩니다.

### 2.1 메시지 헤더 (24바이트)

| 오프셋 | 크기 | 필드 | 설명 |
| :--- | :--- | :--- | :--- |
| 0 | 4 | `magic` | ASCII "ANDM" (`0x41 0x4E 0x44 0x4D`) |
| 4 | 1 | `version` | 프로토콜 버전 (현재 `1`) |
| 5 | 1 | `type` | 메시지 타입 (아래 참조) |
| 6 | 2 | `flags` | 비트 0: IDR 프레임 여부 (`VIDEO` 메시지용) |
| 8 | 4 | `payloadLength` | 페이로드 길이 (최대 8 MiB) |
| 12 | 4 | `sequence` | 증가하는 시퀀스 번호 |
| 16 | 8 | `ptsMicros` | 마이크로초 단위의 프레젠테이션 타임스탬프 |

### 2.2 메시지 타입

| 타입 | 값 | 방향 | 설명 |
| :--- | :---: | :--- | :--- |
| `HELLO` | 1 | Android -> Mac | 패널 크기 및 디코더 기능 (JSON) |
| `CONFIG` | 2 | Mac -> Android | 스트림 설정 (JSON) |
| `CODEC_CONFIG` | 3 | Mac -> Android | Annex B 파라미터 세트 (SPS/PPS) |
| `VIDEO` | 4 | Mac -> Android | 비디오 데이터 유닛 (Annex B) |
| `PING` | 5 | 양방향 | 하트비트 또는 연결 확인 |
| `PONG` | 6 | 양방향 | `PING`에 대한 응답 |
| `STOP` | 7 | 양방향 | 정상 종료 알림 |
| `ERROR` | 8 | 양방향 | 오류 보고 (JSON) |
| `KEYFRAME_REQUEST`| 9 | Android -> Mac | 즉시 IDR 프레임 전송 요청 |

---

## 3. 세션 관리

### 3.1 연결 수립
1.  **핸드셰이크**: 호스트가 Android를 액세서리 모드로 전환합니다.
2.  **인사 (Greeting)**: Android가 액세서리 스트림을 열고 화면 속성을 포함한 `HELLO`를 보냅니다.
3.  **협상 (Negotiation)**: 호스트가 해상도를 확인하고 `CONFIG`를 보냅니다.
4.  **검증 (Verification)**: 호스트가 `PING`을 보내고 `PONG`을 기다립니다.
5.  **스트리밍**: 호스트가 `CODEC_CONFIG`를 보내고 이어서 `VIDEO` 프레임을 전송합니다.

### 3.2 안정성 관리
*   **하트비트**: 호스트는 2초마다 `PING`을 보냅니다. 3초 내에 `PONG`이 없으면 세션이 종료된 것으로 간주합니다.
*   **재동기화**: Android 앱이 백그라운드에서 복귀하면 새로운 `HELLO`를 보냅니다. 호스트는 인코더를 재시작하여 새로운 파라미터 세트를 제공합니다.
*   **키프레임 복구**: Android 디코더에서 문제가 발생하면 `KEYFRAME_REQUEST`를 보내 즉시 IDR 프레임을 유도합니다.
