--[[
Copyright (c) 2011-2015, Vsevolod Stakhov <vsevolod@highsecure.ru>

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
]]--

-- Emails is module for different checks for emails inside messages

if confighelp then
  return
end

-- Rules format:
-- symbol = sym, map = file:///path/to/file, domain_only = yes
-- symbol = sym2, dnsbl = bl.somehost.com, domain_only = no
local rules = {}
local logger = require "rspamd_logger"
local hash = require "rspamd_cryptobox_hash"
local N = "emails"

-- Check rule for a single email
local function check_email_rule(task, rule, addr)
  if rule['dnsbl'] then
    local email
    local to_resolve

    if rule['domain_only'] then
      email = addr:get_host()
    else
      if not rule['hash'] then
        email = string.format('%s.%s', addr:get_user(), addr:get_host())
      else
        email = string.format('%s@%s', addr:get_user(), addr:get_host())
      end
    end

    local function emails_dns_cb(_, _, results, err)
      if err and (err ~= 'requested record is not found'
          and err ~= 'no records with this name') then
        logger.errx(task, 'Error querying DNS: %1', err)
      elseif results then
        if rule['hash'] then
          task:insert_result(rule['symbol'], 1.0, {email, to_resolve})
        else
          task:insert_result(rule['symbol'], 1.0, email)
        end

      end
    end

    logger.debugm(N, task, "check %s on %s", email, rule['dnsbl'])

    if rule['hash'] then
      to_resolve = hash.create_specific(rule['hash'], email):hex()
    else
      to_resolve = email
    end

    local dns_arg = string.format('%s.%s', to_resolve, rule['dnsbl'])

    logger.debugm(N, task, "query %s", dns_arg)

    task:get_resolver():resolve_a({
      task=task,
      name = dns_arg,
      callback = emails_dns_cb})
  elseif rule['map'] then
    if rule['domain_only'] then
      local key = addr:get_host()
      if rule['map']:get_key(key) then
        task:insert_result(rule['symbol'], 1)
        logger.infox(task, '<%1> email: \'%2\' is found in list: %3',
          task:get_message_id(), key, rule['symbol'])
      end
    else
      local key = string.format('%s@%s', addr:get_user(), addr:get_host())
      if rule['map']:get_key(key) then
        task:insert_result(rule['symbol'], 1)
        logger.infox(task, '<%1> email: \'%2\' is found in list: %3',
          task:get_message_id(), key, rule['symbol'])
      end
    end
  end
end

-- Check email
local function check_emails(task)
  local emails = task:get_emails()
  local checked = {}
  if emails then
    for _,addr in ipairs(emails) do
      local to_check = string.format('%s@%s', addr:get_user(), addr:get_host())
      if not checked['to_check'] then
        for _,rule in ipairs(rules) do
          check_email_rule(task, rule, addr)
        end
        checked[to_check] = true
      end
    end
  end
end

local opts =  rspamd_config:get_all_opt('emails', 'rule')
if opts and type(opts) == 'table' then
  local r = opts['rule']

  if r then
    for k,v in pairs(r) do
      local rule = v
      if not rule['symbol'] then
        rule['symbol'] = k
      end

      if rule['map'] then
        rule['name'] = rule['map']
        rule['map'] = rspamd_config:add_map({
           url = rule['name'],
           description = string.format('Emails rule %s', rule['symbol']),
           type = 'regexp'
        })
      end
      if not rule['symbol'] or (not rule['map'] and not rule['dnsbl']) then
        logger.errx(rspamd_config, 'incomplete rule')
      else
        table.insert(rules, rule)
        logger.infox(rspamd_config, 'add emails rule %s',
          rule['dnsbl'] or rule['name'] or '???')
      end
    end
  end
end

if #rules > 0 then
  -- add fake symbol to check all maps inside a single callback
  local id = rspamd_config:register_symbol({
    type = 'callback',
    callback = check_emails
  })
  for _,rule in ipairs(rules) do
    rspamd_config:register_symbol({
      name = rule['symbol'],
      type = 'virtual',
      parent = id
    })
  end
end
