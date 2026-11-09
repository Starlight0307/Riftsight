# Riftsight

맥 전용 롤·TFT 도우미. 앱을 열면 OP.GG 데스크톱 앱처럼 정보 창이 뜨고, 메뉴바(◈)에 상주하며 게임 위에 오버레이를 띄운다.

**앱 창**
- **롤 챔피언 티어**: 탑·정글·미드·원딜·서포터 5열(OP.GG 티어·승률). 챔피언을 누르면 룬·시작/핵심 아이템·신발·스킬 순서를 아이콘으로
- **TFT 메타 덱**: 덱 등급(OP/S…), 유닛 그림(핵심 유닛 금테), 평균 등수·순방률·1등률

**게임 위 오버레이**

- **롤 챔프 선택·게임 중**: 내 챔피언의 OP.GG 빌드(룬·시작/핵심 아이템·신발·스킬 순서)
- **롤 증강체(무작위 총력전 등)**: 선택 화면의 증강체 이름을 읽어 그 위에 OP.GG 티어 + 희귀도(실버·골드·프리즘, 색으로 구분) 배지
- **TFT 게임 중**: OP.GG 메타 덱 상위 5개 + 증강체 위에 내가 정한 등급(S~D) 배지

## 데이터
- 롤 빌드·TFT 메타 덱: [OP.GG 공식 MCP 서버](https://github.com/opgginc/opgg-mcp)
- 롤 증강체: 티어는 OP.GG `lol_list_aram_augments`, 희귀도는 Community Dragon `cherry-augments.json`
- TFT 증강체 등급: 공개 데이터가 없어(OP.GG 공식 데이터·Riot match API 모두 없음) 직접 채우는 등급표 사용
- 아이콘: Riot Data Dragon(챔피언·아이템·룬), Community Dragon(TFT 유닛, 하루 한 번 받아 캐시)
- 게임 정보: 롤 클라이언트의 로컬 API(라이브 클라이언트·LCU)만 읽음. 게임 메모리는 건드리지 않음.

## 설치

1. [Releases](https://github.com/Starlight0307/Riftsight/releases/latest)에서 **Riftsight.dmg**를 받는다.
2. DMG를 열고 **Riftsight**를 **응용 프로그램(Applications)** 폴더로 끌어 놓는다.
3. 처음 한 번은 응용 프로그램 폴더에서 Riftsight를 **오른쪽 클릭 → 열기 → 열기**. (애플 공증을 받지 않은 앱이라 더블클릭하면 막힌다. 그래도 막히면 **시스템 설정 → 개인정보 보호 및 보안** 아래쪽의 **그래도 열기**)
4. 메뉴바에 **◈**가 생기면 실행된 것이다.
5. 처음 증강체 화면을 읽을 때 **화면 기록** 권한을 묻는다 → **시스템 설정 → 개인정보 보호 및 보안 → 화면 및 시스템 오디오 녹음**에서 Riftsight를 켜고, ◈ → 종료 후 다시 실행.

요구 사항: macOS 14 이상, 애플 실리콘(M1 이후) 맥. 롤은 **설정 → 비디오 → 창 모드: 테두리 없음** 권장.
로그인할 때 자동으로 켜려면 **시스템 설정 → 일반 → 로그인 항목**에 Riftsight 추가.

### 메뉴바 ◈
- **Riftsight 열기** — 앱 창(닫아도 메뉴바에 남아 오버레이는 계속 동작)
- **오버레이 보이기/숨기기**
- **TFT 등급표 열기** — 아래 참고
- **종료**

### DMG 직접 만들기
```sh
bash tools/make-dmg.sh 0.1.0    # dist/Riftsight.dmg (아이콘: assets/AppIcon.png)
```

## 개발 중 실행
```sh
swift run -c release            # 실행 (macOS 14+)
swift run Riftsight --selftest  # 해석기·증강체 매칭 자체 점검
```
처음 TFT 게임에서 맥이 **화면 기록** 권한을 물으면 허용한다(증강체 글자 읽기용). 롤은 **테두리 없는 창 모드**를 권장.

## TFT 증강체 등급표
메뉴바 ◈ → **TFT 등급표 열기**. OP.GG의 현재 증강체 이름이 `? 이름  # 희귀도` 꼴로 채워져 있다. 맨 앞 `?`를 S·A·B·C·D로 바꾸고 저장하면 다음 화면 읽기부터 바로 반영된다(다시 빌드 필요 없음).
파일 위치: `~/Library/Application Support/Riftsight/tft_tiers.txt`. 앱을 켤 때마다 OP.GG 목록에 맞춰 자동 갱신(넣은 등급 유지, 새 증강체는 `?`, 사라진 증강체는 빠지고 이전 파일은 `tft_tiers.bak.txt`로 백업).

Riftsight는 Riot Games의 보증을 받지 않았으며 Riot Games의 견해를 대변하지 않습니다.
