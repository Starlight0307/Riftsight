#!/usr/bin/env python3
"""Riot 공식 API 로 TFT 증강체 등급을 계산해 앱 등급표를 만든다.

    RIOT_API_KEY=RGAPI-... python3 tools/augment_tiers.py [경기 수, 기본 300]

한국 챌린저 → 최근 랭크 게임 → 증강체별 평균 등수 → 등급.
결과: Sources/Riftsight/Resources/augment_tiers.json (한글 이름 기준, 앱이 화면 글자와 맞춤)
개발용 키 한도(2분에 100번)에 맞춰 천천히 부르므로 300경기에 약 7~8분 걸린다.
"""
import json, os, sys, time, urllib.error, urllib.request
from collections import defaultdict

KEY = os.environ.get("RIOT_API_KEY")
PLATFORM, REGION = "https://kr.api.riotgames.com", "https://asia.api.riotgames.com"
OUT = os.path.join(os.path.dirname(__file__), "..", "Sources", "Riftsight", "Resources", "augment_tiers.json")
MIN_GAMES = 10  # 이보다 적게 나온 증강체는 등급을 매기지 않음


def get(url, auth=True):
    for _ in range(5):
        # Riot·Community Dragon 모두 파이썬 기본 User-Agent 를 403 으로 막는다
        req = urllib.request.Request(url, headers={"User-Agent": "Riftsight", **({"X-Riot-Token": KEY} if auth else {})})
        try:
            with urllib.request.urlopen(req, timeout=20) as r:
                if auth:
                    time.sleep(1.25)  # 2분 100번 한도
                return json.load(r)
        except urllib.error.HTTPError as e:
            if e.code == 429:
                time.sleep(int(e.headers.get("Retry-After", 10)))
                continue
            raise
    raise RuntimeError("요청이 계속 거절됨: " + url)


# shortcut: 평균 등수 고정 구간으로 등급을 나눔, 메타가 크게 바뀌면 백분위 기준으로 바꾸기
def tier(avg):
    for t, cut in (("S", 4.0), ("A", 4.3), ("B", 4.6), ("C", 4.9)):
        if avg <= cut:
            return t
    return "D"


def main():
    if not KEY:
        sys.exit("RIOT_API_KEY 가 없어요. https://developer.riotgames.com 에서 개발용 키를 받아 넣어 주세요.")
    want = int(sys.argv[1]) if len(sys.argv) > 1 else 300

    names = {i["apiName"]: i["name"] for i in get("https://raw.communitydragon.org/latest/cdragon/tft/ko_kr.json", auth=False)["items"] if i.get("apiName")}

    players = get(f"{PLATFORM}/tft/league/v1/challenger")["entries"]
    match_ids = []
    for p in players:
        if len(match_ids) >= want:
            break
        for m in get(f"{REGION}/tft/match/v1/matches/by-puuid/{p['puuid']}/ids?count=10"):
            if m not in match_ids:
                match_ids.append(m)
    match_ids = match_ids[:want]

    places, latest_set = defaultdict(list), 0
    for n, mid in enumerate(match_ids, 1):
        info = get(f"{REGION}/tft/match/v1/matches/{mid}")["info"]
        if info.get("queue_id") != 1100:  # 랭크 게임만
            continue
        latest_set = max(latest_set, info.get("tft_set_number", 0))
        for pl in info["participants"]:
            for a in pl.get("augments", []):
                places[(info.get("tft_set_number", 0), a)].append(pl["placement"])
        print(f"\r경기 {n}/{len(match_ids)}", end="", file=sys.stderr)
    print(file=sys.stderr)

    if not places:  # 기존 등급표를 빈 표로 덮어쓰지 않도록
        sys.exit("경기 데이터에 증강체 정보가 없어요 (Riot 이 이번 시즌 match API 에서 증강체를 빼 둠). 등급표는 그대로 둡니다.")
    augments = {}
    for (s, api), ps in places.items():
        if s != latest_set or len(ps) < MIN_GAMES or api not in names:
            continue
        avg = sum(ps) / len(ps)
        augments[names[api]] = {"tier": tier(avg), "avg": round(avg, 2), "n": len(ps), "api": api}

    json.dump({"set": latest_set, "matches": len(match_ids), "updated": time.strftime("%Y-%m-%d"), "augments": augments},
              open(OUT, "w"), ensure_ascii=False, indent=1, sort_keys=True)
    print(f"증강체 {len(augments)}개 등급 저장 → {os.path.normpath(OUT)}")


assert [tier(x) for x in (3.5, 4.0, 4.2, 4.5, 4.8, 5.5)] == ["S", "S", "A", "B", "C", "D"]

if __name__ == "__main__":
    main()
