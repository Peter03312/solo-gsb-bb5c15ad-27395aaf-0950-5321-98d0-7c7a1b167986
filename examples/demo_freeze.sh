#!/usr/bin/env bash
# 记录临时冻结端到端示例：
#   发布快照 -> 冻结（缺密钥401/未知404/空原因422）-> 重复冻结回放当前冻结期 ->
#   冻结期间公开读取（单快照令牌/共享凭证/假令牌）一律 403 且不扣次数、不写审计 ->
#   冻结期间新发布的快照同样 403，共享凭证中的其他记录仍可读 ->
#   解除后恢复原本仍有效的读取资格（耗尽/撤销不复活）-> 再冻结开启新冻结期
# 依赖：curl、jq
set -euo pipefail

BASE_URL="${BASE_URL:-http://localhost:8000}"
SERVICE_KEY="${SERVICE_KEY:-dev-service-key-change-me}"
ALICE_PW="${ALICE_PW:-alice-pw}"   # operator
BOB_PW="${BOB_PW:-bob-pw}"         # reviewer
AUTH=(-H "X-Service-Key: ${SERVICE_KEY}" -H "Content-Type: application/json")

step() { printf '\n\033[1m== %s ==\033[0m\n' "$1"; }
code() { curl -sS -o /dev/null -w '%{http_code}' "$@"; }
events() { # events <SID>：统计某快照的成功读取审计事件数
  curl -sS -G "${BASE_URL}/snapshots/$1/read-events" "${AUTH[@]}" \
    --data-urlencode "start=2000-01-01T00:00:00Z" \
    --data-urlencode "end=2100-01-01T00:00:00Z" \
    --data-urlencode "limit=500" | jq '.events | length'
}

step "1. 创建记录并发布版本 1：一支上限 3 次的令牌 T1"
CREATE=$(curl -sS -X POST "${BASE_URL}/records" "${AUTH[@]}" -d '{
  "text": "患者张三，身份证号 110101199003077777，联系电话 13800001111。",
  "intervals": [{"start": 2, "end": 4}, {"start": 10, "end": 28}, {"start": 34, "end": 45}]
}')
RECORD_ID=$(echo "${CREATE}" | jq -r .record_id)
PUB1=$(curl -sS -X POST "${BASE_URL}/records/${RECORD_ID}/publish" "${AUTH[@]}" \
  -d '{"version": 1, "max_reads": 3}')
SID1=$(echo "${PUB1}" | jq -r .snapshot_id)
TOK1=$(echo "${PUB1}" | jq -r .token)
echo "冻结前成功读取一次（已用 1 / 共 3）"
curl -sS "${BASE_URL}/public/snapshots/${SID1}?token=${TOK1}" | jq .status

step "2. 冻结鉴权与入参：缺密钥 401、未知记录 404、空白原因 422"
printf '缺服务密钥: HTTP %s\n' "$(code -X POST "${BASE_URL}/records/${RECORD_ID}/freeze" \
  -H 'Content-Type: application/json' -d '{"reason":"x"}')"
UNKNOWN="00000000-0000-0000-0000-000000000000"
printf '未知记录:   HTTP %s\n' "$(code -X POST "${BASE_URL}/records/${UNKNOWN}/freeze" "${AUTH[@]}" \
  -d '{"reason":"x"}')"
printf '缺少原因:   HTTP %s\n' "$(code -X POST "${BASE_URL}/records/${RECORD_ID}/freeze" "${AUTH[@]}" \
  -d '{}')"
printf '空白原因:   HTTP %s\n' "$(code -X POST "${BASE_URL}/records/${RECORD_ID}/freeze" "${AUTH[@]}" \
  -d '{"reason":"   "}')"

step "3. 首次冻结：返回冻结期标识、原因与开始时间"
FREEZE=$(curl -sS -X POST "${BASE_URL}/records/${RECORD_ID}/freeze" "${AUTH[@]}" \
  -d '{"reason":"接到临时阻断通知，暂停外部阅览"}')
echo "${FREEZE}" | jq .
FREEZE_ID=$(echo "${FREEZE}" | jq -r .freeze_id)
FROZEN_AT=$(echo "${FREEZE}" | jq -r .frozen_at)

step "4. 重复冻结（不同原因/空原因）幂等回放当前冻结期，原因与开始时间不被覆盖"
curl -sS -X POST "${BASE_URL}/records/${RECORD_ID}/freeze" "${AUTH[@]}" \
  -d '{"reason":"另一个原因"}' | jq .
printf '不同原因/空原因回放均保持首次值: '
curl -sS -X POST "${BASE_URL}/records/${RECORD_ID}/freeze" "${AUTH[@]}" -d '{}' \
  | jq --arg fid "${FREEZE_ID}" --arg at "${FROZEN_AT}" -e \
  '.already_frozen == true and .freeze_id == $fid and .frozen_at == $at
   and .reason == "接到临时阻断通知，暂停外部阅览"'

step "5. 维护侧查询冻结状态（原因仅维护侧可见）"
curl -sS "${BASE_URL}/records/${RECORD_ID}/freeze" "${AUTH[@]}" | jq .

step "6. 冻结期间公开读取一律 403 snapshot unavailable，不扣次数、不写审计"
for T in "${TOK1}" "not-a-token"; do
  printf 'HTTP %s  ' "$(code "${BASE_URL}/public/snapshots/${SID1}?token=${T}")"
  curl -sS "${BASE_URL}/public/snapshots/${SID1}?token=${T}"
  echo
done
curl -sS "${BASE_URL}/tokens/${TOK1}" "${AUTH[@]}" \
  | jq '{reads_used, remaining_reads, active}'
echo "快照审计事件数（仍为冻结前的 1 条）: $(events "${SID1}")"

step "7. 冻结覆盖期间新发布的快照（发布照常，但新快照读取 403）"
curl -sS -X PUT "${BASE_URL}/records/${RECORD_ID}" "${AUTH[@]}" -d '{
  "base_version": 1,
  "text": "患者李四，联系方式已变更。",
  "intervals": [{"start": 2, "end": 4}]
}' | jq .
PUB2=$(curl -sS -X POST "${BASE_URL}/records/${RECORD_ID}/publish" "${AUTH[@]}" \
  -d '{"version": 2}')
SID2=$(echo "${PUB2}" | jq -r .snapshot_id)
TOK2=$(echo "${PUB2}" | jq -r .token)
printf '冻结期间新快照读取: HTTP %s\n' \
  "$(code "${BASE_URL}/public/snapshots/${SID2}?token=${TOK2}")"

step "8. 共享凭证中其他记录的快照仍可读，冻结项不扣共享额度"
OTHER=$(curl -sS -X POST "${BASE_URL}/records" "${AUTH[@]}" -d '{
  "text": "另一条记录，正常公开。", "intervals": [{"start": 0, "end": 2}]}')
OTHER_RID=$(echo "${OTHER}" | jq -r .record_id)
OTHER_PUB=$(curl -sS -X POST "${BASE_URL}/records/${OTHER_RID}/publish" "${AUTH[@]}" \
  -d '{"version": 1, "max_reads": 10}')
OTHER_SID=$(echo "${OTHER_PUB}" | jq -r .snapshot_id)
BREQ=$(curl -sS -X POST "${BASE_URL}/bundle-requests" \
  -u "alice:${ALICE_PW}" -H 'Content-Type: application/json' \
  -d "{\"snapshot_ids\":[\"${SID1}\",\"${OTHER_SID}\"],\"max_reads\":5}" | jq -r .request_id)
BAPP=$(curl -sS -X POST "${BASE_URL}/bundle-requests/${BREQ}/approve" -u "bob:${BOB_PW}")
CRED=$(echo "${BAPP}" | jq -r .credential)
BID=$(echo "${BAPP}" | jq -r .bundle_id)
printf '冻结项: HTTP %s（不扣共享额度）\n' \
  "$(code "${BASE_URL}/public/snapshots/${SID1}?token=${CRED}")"
printf '其他记录项: HTTP %s（继续可读）\n' \
  "$(code "${BASE_URL}/public/snapshots/${OTHER_SID}?token=${CRED}")"
curl -sS "${BASE_URL}/read-bundles/${BID}" "${AUTH[@]}" | jq '{reads_used, remaining_reads, active}'

step "9. 解除冻结：幂等；恢复原本仍有效的读取资格"
curl -sS -X POST "${BASE_URL}/records/${RECORD_ID}/unfreeze" "${AUTH[@]}" | jq .
printf '再次解除（幂等回放）: '
curl -sS -X POST "${BASE_URL}/records/${RECORD_ID}/unfreeze" "${AUTH[@]}" \
  | jq -e '.unfrozen == false and .already_unfrozen == true and .freeze_id != null'
printf '版本 1 恢复可读: HTTP %s（已用回到 2 / 共 3，还剩 1 次）\n' \
  "$(code "${BASE_URL}/public/snapshots/${SID1}?token=${TOK1}")"
curl -sS "${BASE_URL}/tokens/${TOK1}" "${AUTH[@]}" | jq '{reads_used, remaining_reads, active}'
printf '最后一次有效读取: HTTP %s；此后额度耗尽，继续读取 403（解除不复活额度）\n' \
  "$(code "${BASE_URL}/public/snapshots/${SID1}?token=${TOK1}")"
printf '耗尽后读取:       HTTP %s\n' \
  "$(code "${BASE_URL}/public/snapshots/${SID1}?token=${TOK1}")"
printf '共享凭证中的冻结项也恢复可读: HTTP %s\n' \
  "$(code "${BASE_URL}/public/snapshots/${SID1}?token=${CRED}")"

step "10. 再冻结开启一个新的冻结期（标识、原因与开始时间全新）"
REFREEZE=$(curl -sS -X POST "${BASE_URL}/records/${RECORD_ID}/freeze" "${AUTH[@]}" \
  -d '{"reason":"二次临时阻断"}')
echo "${REFREEZE}" | jq '{freeze_id, reason, frozen_at, already_frozen}'
echo "新冻结期标识不同于上次: $(echo "${REFREEZE}" | jq --arg fid "${FREEZE_ID}" -e '.freeze_id != $fid')"
printf '读取再次 403: HTTP %s\n' "$(code "${BASE_URL}/public/snapshots/${SID2}?token=${TOK2}")"
# 收尾解除，便于重复演示
curl -sS -X POST "${BASE_URL}/records/${RECORD_ID}/unfreeze" "${AUTH[@]}" >/dev/null

printf '\n\033[1m记录临时冻结演示完成。\033[0m\n'
