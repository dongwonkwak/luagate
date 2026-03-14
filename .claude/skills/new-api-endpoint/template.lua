-- lua/luagate/admin/handlers/TEMPLATE.lua
-- 이 파일을 복사하여 새 핸들러 작성
-- 참조: .claude/skills/new-api-endpoint/SKILL.md, docs/spec/admin-api.md

local M = {}
local cjson = require("cjson")
local audit = require("luagate.log.audit")
local auth   = require("luagate.admin.auth")

-- 핸들러 진입점
function M.handle()
    local method = ngx.req.get_method()

    -- 인증 검사 (GET /health 등 예외 시 이 블록 제거)
    if not auth.verify() then
        return  -- auth.verify()가 401 응답 후 ngx.exit() 처리
    end

    if method == "GET" then
        M._get()
    elseif method == "POST" then
        M._post()
    else
        ngx.status = 405
        ngx.say(cjson.encode({
            ok = false,
            error = "MethodNotAllowed",
            message = method .. " not allowed"
        }))
        ngx.exit(405)
    end
end

function M._get()
    -- 조회 로직
    local data = {}

    ngx.status = 200
    ngx.say(cjson.encode({ ok = true, data = data }))
    ngx.exit(200)
end

function M._post()
    ngx.req.read_body()
    local body = ngx.req.get_body_data()

    -- TODO: 처리 로직

    -- 감사 로그 (상태 변경 시 필수)
    audit.log("my_event", {
        src_ip = ngx.var.remote_addr,
        -- 추가 필드
    })

    ngx.status = 200
    ngx.say(cjson.encode({ ok = true, data = {} }))
    ngx.exit(200)
end

return M
