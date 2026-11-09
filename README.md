# Riftsight

맥 전용 롤·TFT 오버레이. 메뉴바(◈)에 상주하며 게임 위에 정보를 띄운다.

- **롤 챔프 선택·게임 중**: 내 챔피언의 OP.GG 빌드(룬·시작/핵심 아이템·신발·스킬 순서)
- **롤 증강체(무작위 총력전 등)**: 선택 화면의 증강체 이름을 읽어 그 위에 등급 배지(S~D). OP.GG 챔피언별 증강체 성능 점수 순위로 매김
- **TFT 게임 중**: OP.GG 메타 덱 상위 5개 + 증강체 등급 배지(등급표가 있을 때만 — 아래 참고)

## 데이터
- 롤 빌드·TFT 메타 덱: [OP.GG 공식 MCP 서버](https://github.com/opgginc/opgg-mcp)
- 롤 증강체 등급: OP.GG `lol_list_aram_augments`의 성능 점수 (OP.GG의 tier 값은 희귀도라 쓰지 않음)
- TFT 증강체 등급: OP.GG 공식 데이터에 없음. Riot match API도 시즌 18부터 증강체를 빼서 `tools/augment_tiers.py`는 지금 쓸 수 없음
- 게임 정보: 롤 클라이언트의 로컬 API(라이브 클라이언트·LCU)만 읽음. 게임 메모리는 건드리지 않음.

## 실행
```sh
swift run -c release            # 실행 (macOS 14+)
swift run Riftsight --selftest  # 해석기·증강체 매칭 자체 점검
```
처음 TFT 게임에서 맥이 **화면 기록** 권한을 물으면 허용한다(증강체 글자 읽기용). 롤은 **테두리 없는 창 모드**를 권장.

## 증강체 등급표 갱신
```sh
RIOT_API_KEY=RGAPI-... python3 tools/augment_tiers.py 300   # 한국 챌린저 최근 300경기
swift build -c release                                       # 등급표는 앱에 묶이므로 다시 빌드
```

Riftsight는 Riot Games의 보증을 받지 않았으며 Riot Games의 견해를 대변하지 않습니다.
