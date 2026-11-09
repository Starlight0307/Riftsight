# Riftsight

맥 전용 롤·TFT 오버레이. 메뉴바(◈)에 상주하며 게임 위에 정보를 띄운다.

- **롤 챔프 선택·게임 중**: 내 챔피언의 OP.GG 빌드(룬·시작/핵심 아이템·신발·스킬 순서)
- **롤 증강체(무작위 총력전 등)**: 선택 화면의 증강체 이름을 읽어 그 위에 OP.GG 티어 + 희귀도(실버·골드·프리즘, 색으로 구분) 배지
- **TFT 게임 중**: OP.GG 메타 덱 상위 5개 + 증강체 위에 내가 정한 등급(S~D) 배지

## 데이터
- 롤 빌드·TFT 메타 덱: [OP.GG 공식 MCP 서버](https://github.com/opgginc/opgg-mcp)
- 롤 증강체: 티어는 OP.GG `lol_list_aram_augments`, 희귀도는 Community Dragon `cherry-augments.json`
- TFT 증강체 등급: 공개 데이터가 없어(OP.GG 공식 데이터·Riot match API 모두 없음) 직접 채우는 등급표 사용
- 게임 정보: 롤 클라이언트의 로컬 API(라이브 클라이언트·LCU)만 읽음. 게임 메모리는 건드리지 않음.

## 실행
```sh
swift run -c release            # 실행 (macOS 14+)
swift run Riftsight --selftest  # 해석기·증강체 매칭 자체 점검
```
처음 TFT 게임에서 맥이 **화면 기록** 권한을 물으면 허용한다(증강체 글자 읽기용). 롤은 **테두리 없는 창 모드**를 권장.

## TFT 증강체 등급표
메뉴바 ◈ → **TFT 등급표 열기**. 처음 열면 OP.GG의 이번 시즌 증강체 이름이 `? 이름  # 희귀도` 꼴로 채워져 있다. 맨 앞 `?`를 S·A·B·C·D로 바꾸고 저장하면 다음 화면 읽기부터 바로 반영된다(다시 빌드 필요 없음).
파일 위치: `~/Library/Application Support/Riftsight/tft_tiers.txt` — 시즌이 바뀌면 지우고 다시 열면 새 양식이 만들어진다.

Riftsight는 Riot Games의 보증을 받지 않았으며 Riot Games의 견해를 대변하지 않습니다.
