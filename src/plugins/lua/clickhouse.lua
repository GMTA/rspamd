--[[
Copyright (c) 2016, Vsevolod Stakhov <vsevolod@highsecure.ru>

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

local rspamd_logger = require 'rspamd_logger'
local rspamd_http = require "rspamd_http"
local rspamd_lua_utils = require "lua_util"
local upstream_list = require "rspamd_upstream_list"
local lua_util = require "lua_util"
local ucl = require "ucl"

local N = "clickhouse"

if confighelp then
  return
end

local E = {}

local rows = {}
local attachment_rows = {}
local urls_rows = {}
local emails_rows = {}
local specific_rows = {}
local asn_rows = {}
local symbols_rows = {}
local custom_rows = {}
local nrows = 0
local connect_prefix = 'http://'

local settings = {
  limit = 1000,
  timeout = 5.0,
  bayes_spam_symbols = {'BAYES_SPAM'},
  bayes_ham_symbols = {'BAYES_HAM'},
  fann_symbols = {'FANN_SCORE'},
  fuzzy_symbols = {'FUZZY_DENIED'},
  whitelist_symbols = {'WHITELIST_DKIM', 'WHITELIST_SPF_DKIM', 'WHITELIST_DMARC'},
  dkim_allow_symbols = {'R_DKIM_ALLOW'},
  dkim_reject_symbols = {'R_DKIM_REJECT'},
  dmarc_allow_symbols = {'DMARC_POLICY_ALLOW'},
  dmarc_reject_symbols = {'DMARC_POLICY_REJECT', 'DMARC_POLICY_QUARANTINE'},
  stop_symbols = {},
  table = 'rspamd',
  attachments_table = 'rspamd_attachments',
  urls_table = 'rspamd_urls',
  emails_table = 'rspamd_emails',
  symbols_table = 'rspamd_symbols',
  asn_table = 'rspamd_asn',
  ipmask = 19,
  ipmask6 = 48,
  full_urls = false,
  from_tables = nil,
  enable_symbols = false,
  use_https = false,
  use_gzip = true,
  allow_local = false,
  user = nil,
  password = nil,
  no_ssl_verify = false,
  custom_rules = {},
  retention = {
    enable = false,
    method = 'detach',
    period_months = 3,
    run_every = '7d',
  }
}

local clickhouse_schema = {
table = [[
CREATE TABLE IF NOT EXISTS ${table}
(
    Date Date,
    TS DateTime,
    From String,
    MimeFrom String,
    IP String,
    Score Float64,
    NRcpt UInt8,
    Size UInt32,
    IsWhitelist Enum8('blacklist' = 0, 'whitelist' = 1, 'unknown' = 2) DEFAULT CAST('unknown' AS Enum8('blacklist' = 0, 'whitelist' = 1, 'unknown' = 2)),
    IsBayes Enum8('ham' = 0, 'spam' = 1, 'unknown' = 2) DEFAULT CAST('unknown' AS Enum8('ham' = 0, 'spam' = 1, 'unknown' = 2)),
    IsFuzzy Enum8('whitelist' = 0, 'deny' = 1, 'unknown' = 2) DEFAULT CAST('unknown' AS Enum8('whitelist' = 0, 'deny' = 1, 'unknown' = 2)),
    IsFann Enum8('ham' = 0, 'spam' = 1, 'unknown' = 2) DEFAULT CAST('unknown' AS Enum8('ham' = 0, 'spam' = 1, 'unknown' = 2)),
    IsDkim Enum8('reject' = 0, 'allow' = 1, 'unknown' = 2) DEFAULT CAST('unknown' AS Enum8('reject' = 0, 'allow' = 1, 'unknown' = 2)),
    IsDmarc Enum8('reject' = 0, 'allow' = 1, 'unknown' = 2) DEFAULT CAST('unknown' AS Enum8('reject' = 0, 'allow' = 1, 'unknown' = 2)),
    NUrls Int32,
    Action Enum8('reject' = 0, 'rewrite subject' = 1, 'add header' = 2, 'greylist' = 3, 'no action' = 4, 'soft reject' = 5) DEFAULT CAST('no action' AS Enum8('reject' = 0, 'rewrite subject' = 1, 'add header' = 2, 'greylist' = 3, 'no action' = 4, 'soft reject' = 5)),
    FromUser String,
    MimeUser String,
    RcptUser String,
    RcptDomain String,
    ListId String,
    Digest FixedString(32)
) ENGINE = MergeTree(Date, (TS, From), 8192)
]],

attachments_table = [[
CREATE TABLE IF NOT EXISTS ${attachments_table} (
    Date Date,
    Digest FixedString(32),
    `Attachments.FileName` Array(String),
    `Attachments.ContentType` Array(String),
    `Attachments.Length` Array(UInt32),
    `Attachments.Digest` Array(FixedString(16))
) ENGINE = MergeTree(Date, Digest, 8192)
]],

urls_table = [[
CREATE TABLE IF NOT EXISTS ${urls_table} (
    Date Date,
    Digest FixedString(32),
    `Urls.Tld` Array(String),
    `Urls.Url` Array(String)
) ENGINE = MergeTree(Date, Digest, 8192)
]],

emails_table = [[
CREATE TABLE IF NOT EXISTS ${emails_table} (
    Date Date,
    Digest FixedString(32),
    Emails Array(String)
) ENGINE = MergeTree(Date, Digest, 8192)
]],

asn_table = [[
CREATE TABLE IF NOT EXISTS ${asn_table} (
    Date Date,
    Digest FixedString(32),
    ASN String,
    Country FixedString(2),
    IPNet String
) ENGINE = MergeTree(Date, Digest, 8192)
]],

symbols_table = [[
CREATE TABLE IF NOT EXISTS ${symbols_table} (
    Date Date,
    Digest FixedString(32),
    `Symbols.Names` Array(String),
    `Symbols.Scores` Array(Float64),
    `Symbols.Options` Array(String)
) ENGINE = MergeTree(Date, Digest, 8192)
]]
}

local function clickhouse_main_row(tname)
  local fields = {
    'Date',
    'TS',
    'From',
    'MimeFrom',
    'IP',
    'Score',
    'NRcpt',
    'Size',
    'IsWhitelist',
    'IsBayes',
    'IsFuzzy',
    'IsFann',
    'IsDkim',
    'IsDmarc',
    'NUrls',
    'Action',
    'FromUser',
    'MimeUser',
    'RcptUser',
    'RcptDomain',
    'ListId',
    'Digest'
  }
  local elt = string.format('INSERT INTO %s (%s) VALUES ',
    tname, table.concat(fields, ','))

  return elt
end

local function clickhouse_attachments_row(tname)
  local attachement_fields = {
    'Date',
    'Digest',
    'Attachments.FileName',
    'Attachments.ContentType',
    'Attachments.Length',
    'Attachments.Digest',
  }
  local elt = string.format('INSERT INTO %s (%s) VALUES ',
    tname, table.concat(attachement_fields, ','))
  return elt
end

local function clickhouse_urls_row(tname)
  local urls_fields = {
    'Date',
    'Digest',
    'Urls.Tld',
    'Urls.Url',
  }
  local elt = string.format('INSERT INTO %s (%s) VALUES ',
    tname, table.concat(urls_fields, ','))
  return elt
end

local function clickhouse_emails_row(tname)
  local emails_fields = {
    'Date',
    'Digest',
    'Emails',
  }
  local elt = string.format('INSERT INTO %s (%s) VALUES ',
      tname, table.concat(emails_fields, ','))
  return elt
end

local function clickhouse_symbols_row(tname)
  local symbols_fields = {
    'Date',
    'Digest',
    'Symbols.Names',
    'Symbols.Scores',
    'Symbols.Options',
  }
  local elt = string.format('INSERT INTO %s (%s) VALUES ',
    tname, table.concat(symbols_fields, ','))
  return elt
end

local function clickhouse_asn_row(tname)
  local asn_fields = {
    'Date',
    'Digest',
    'ASN',
    'Country',
    'IPNet',
  }
  local elt = string.format('INSERT INTO %s (%s) VALUES ',
    tname, table.concat(asn_fields, ','))
  return elt
end

local function clickhouse_first_row()
  table.insert(rows, clickhouse_main_row(settings['table']))
  if settings['attachments_table'] then
    table.insert(attachment_rows,
      clickhouse_attachments_row(settings['attachments_table']))
  end
  if settings['urls_table'] then
    table.insert(urls_rows,
      clickhouse_urls_row(settings['urls_table']))
  end
  if settings['emails_table'] then
    table.insert(emails_rows,
        clickhouse_emails_row(settings['emails_table']))
  end
  if settings['asn_table'] then
    table.insert(asn_rows,
      clickhouse_asn_row(settings['asn_table']))
  end
  if settings.enable_symbols and settings['symbols_table'] then
    table.insert(symbols_rows,
      clickhouse_symbols_row(settings['symbols_table']))
  end

  for k,rule in pairs(settings.custom_rules) do
    if not custom_rows[k] then custom_rows[k] = {} end
    table.insert(custom_rows[k],
        rule.first_row())
  end
end

local function clickhouse_check_symbol(task, symbols, need_score)
  for _,s in ipairs(symbols) do
    if task:has_symbol(s) then
      if need_score then
        local sym = task:get_symbol(s)[1]
        return sym['score']
      else
        return true
      end
    end
  end

  return false
end

local function clickhouse_send_data(task)
  local upstream = settings.upstream:get_upstream_round_robin()
  local ip_addr = upstream:get_addr():to_string(true)

  local function gen_http_cb(what, how_many)
    return function (err_message, code, data, _)
      if code ~= 200 or err_message then
        if not err_message then err_message = data end
        rspamd_logger.errx(task, "cannot send %s data to clickhouse server %s: %s",
            what, ip_addr, err_message)
        upstream:fail()
      else
        rspamd_logger.infox(task, "sent %s rows of %s to clickhouse server %s",
            how_many - 1, what, ip_addr)
        upstream:ok()
      end
    end
  end

  local body = table.concat(rows, ' ')
  if not rspamd_http.request({
      task = task,
      url = connect_prefix .. ip_addr,
      body = body,
      callback = gen_http_cb('generic data', #rows),
      gzip = settings.use_gzip,
      mime_type = 'text/plain',
      timeout = settings['timeout'],
      no_ssl_verify = settings.no_ssl_verify,
      user = settings.user,
      password = settings.password,
    }) then
     rspamd_logger.errx(task, "cannot send data to clickhouse server %s: cannot make request",
        settings['server'])
  end

  if #attachment_rows > 1 then
    body = table.concat(attachment_rows, ' ')
    if not rspamd_http.request({
      task = task,
      url = connect_prefix .. ip_addr,
      body = body,
      callback = gen_http_cb('attachments data', #attachment_rows),
      mime_type = 'text/plain',
      timeout = settings['timeout'],
      no_ssl_verify = settings.no_ssl_verify,
      user = settings.user,
      password = settings.password,
    }) then
      rspamd_logger.errx(task, "cannot send attachments to clickhouse server %s: cannot make request",
        settings['server'])
    end
  end
  if #urls_rows > 1 then
    body = table.concat(urls_rows, ' ')
    if not rspamd_http.request({
      task = task,
      url = connect_prefix .. ip_addr,
      body = body,
      callback = gen_http_cb('urls data', #urls_rows),
      mime_type = 'text/plain',
      timeout = settings['timeout'],
      no_ssl_verify = settings.no_ssl_verify,
      user = settings.user,
      password = settings.password,
    }) then
      rspamd_logger.errx(task, "cannot send urls to clickhouse server %s: cannot make request",
        settings['server'])
    end
  end
  if #emails_rows > 1 then
    body = table.concat(emails_rows, ' ')
    if not rspamd_http.request({
      task = task,
      url = connect_prefix .. ip_addr,
      body = body,
      callback = gen_http_cb('emails data', #emails_rows),
      mime_type = 'text/plain',
      timeout = settings['timeout'],
      no_ssl_verify = settings.no_ssl_verify,
      user = settings.user,
      password = settings.password,
    }) then
      rspamd_logger.errx(task, "cannot send emails to clickhouse server %s: cannot make request",
          settings['server'])
    end
  end
  if #asn_rows > 1 then
    body = table.concat(asn_rows, ' ')
    if not rspamd_http.request({
      task = task,
      url = connect_prefix .. ip_addr,
      body = body,
      callback = gen_http_cb('asn data', #asn_rows),
      mime_type = 'text/plain',
      timeout = settings['timeout'],
      no_ssl_verify = settings.no_ssl_verify,
      user = settings.user,
      password = settings.password,
    }) then
      rspamd_logger.errx(task, "cannot send asn info to clickhouse server %s: cannot make request",
        settings['server'])
    end
  end

  if #symbols_rows > 1 then
    body = table.concat(symbols_rows, ' ')
    if not rspamd_http.request({
      task = task,
      url = connect_prefix .. ip_addr,
      body = body,
      callback = gen_http_cb('symbols data', #symbols_rows),
      mime_type = 'text/plain',
      timeout = settings['timeout'],
      no_ssl_verify = settings.no_ssl_verify,
      user = settings.user,
      password = settings.password,
    }) then
      rspamd_logger.errx(task, "cannot send symbols info to clickhouse server %s: cannot make request",
        settings['server'])
    end
  end

  for k,specific in pairs(specific_rows) do
    if #specific > 1 then
      body = table.concat(specific, ' ')
      if not rspamd_http.request({
        task = task,
        url = connect_prefix .. ip_addr,
        body = body,
        callback = gen_http_cb('domain specific data ('..k..')', #specific),
        mime_type = 'text/plain',
        timeout = settings['timeout'],
        no_ssl_verify = settings.no_ssl_verify,
        user = settings.user,
        password = settings.password,
      }) then
        rspamd_logger.errx(task, "cannot send data for domain %s to clickhouse server %s: cannot make request",
          k, settings['server'])
      end
    end
  end

  for k,crows in pairs(custom_rows) do
    if #crows > 1 then
      body = table.concat(crows, ' ')
      if not rspamd_http.request({
        task = task,
        url = connect_prefix .. ip_addr,
        body = body,
        callback = gen_http_cb('custom data ('..k..')', #crows),
        mime_type = 'text/plain',
        timeout = settings['timeout'],
        no_ssl_verify = settings.no_ssl_verify,
        user = settings.user,
        password = settings.password,
      }) then
        rspamd_logger.errx(task, "cannot send custom data %s to clickhouse server %s: cannot make request",
            k, settings['server'])
      end
    end
  end
end

local function clickhouse_quote(str)
  if str then
    return str:gsub('[\'\\]', '\\%1'):lower()
  else
    return ''
  end
end

local function clickhouse_collect(task)
  if not settings.allow_local and rspamd_lua_utils.is_rspamc_or_controller(task) then return end

  for _,sym in ipairs(settings.stop_symbols) do
    if task:has_symbol(sym) then
      rspamd_logger.debugm(N, task, 'skip collection as symbol %s has fired', sym)
      return
    end
  end

  local from_domain = ''
  local from_user = ''
  if task:has_from('smtp') then
    local from = task:get_from('smtp')[1]

    if from then
      from_domain = from['domain']
      from_user = from['user']
    end

    if from_domain == '' then
      if task:get_helo() then
        from_domain = task:get_helo()
      end
    end
  else
    if task:get_helo() then
      from_domain = task:get_helo()
    end
  end

  local mime_domain = ''
  local mime_user = ''
  if task:has_from('mime') then
    local from = task:get_from('mime')[1]
    if from then
      mime_domain = from['domain']
      mime_user = from['user']
    end
  end

  local ip_str = 'undefined'
  local ip = task:get_from_ip()
  if ip and ip:is_valid() then
    local ipnet
    if ip:get_version() == 4 then
      ipnet = ip:apply_mask(settings['ipmask'])
    else
      ipnet = ip:apply_mask(settings['ipmask6'])
    end
    ip_str = ipnet:to_string()
  end

  local rcpt_user = ''
  local rcpt_domain = ''
  if task:has_recipients('smtp') then
    local rcpt = task:get_recipients('smtp')[1]
    rcpt_user = rcpt['user']
    rcpt_domain = rcpt['domain']
  end

  local list_id = ''
  local lh = task:get_header('List-Id')
  if lh then
    list_id = lh
  end

  local score = task:get_metric_score('default')[1];
  local bayes = 'unknown';
  local fuzzy = 'unknown';
  local fann = 'unknown';
  local whitelist = 'unknown';
  local dkim = 'unknown';
  local dmarc = 'unknown';

  local ret

  ret = clickhouse_check_symbol(task, settings['bayes_spam_symbols'], false)
  if ret then
    bayes = 'spam'
  end

  ret = clickhouse_check_symbol(task, settings['bayes_ham_symbols'], false)
  if ret then
    bayes = 'ham'
  end

  ret = clickhouse_check_symbol(task, settings['fann_symbols'], true)
  if ret then
    if ret > 0 then
      fann = 'spam'
    else
      fann = 'ham'
    end
  end


  ret = clickhouse_check_symbol(task, settings['whitelist_symbols'], true)
  if ret then
    if ret < 0 then
      whitelist = 'whitelist'
    else
      whitelist = 'blacklist'
    end
  end

  ret = clickhouse_check_symbol(task, settings['fuzzy_symbols'], false)
  if ret then
    fuzzy = 'deny'
  end

  ret = clickhouse_check_symbol(task, settings['dkim_allow_symbols'], false)
  if ret then
    dkim = 'allow'
  end

  ret = clickhouse_check_symbol(task, settings['dkim_reject_symbols'], false)
  if ret then
    dkim = 'reject'
  end

  ret = clickhouse_check_symbol(task, settings['dmarc_allow_symbols'], false)
  if ret then
    dmarc = 'allow'
  end

  ret = clickhouse_check_symbol(task, settings['dmarc_reject_symbols'], false)
  if ret then
    dmarc = 'reject'
  end

  local nrcpts = 0
  if task:has_recipients('smtp') then
    nrcpts = #task:get_recipients('smtp')
  end

  local nurls = 0
  if task:has_urls(true) then
    nurls = #task:get_urls(true)
  end

  local timestamp = task:get_date({
    format = 'connect',
    gmt = false
  })

  local elt = string.format("(today(),%d,'%s','%s','%s',%.2f,%d,%d,'%s','%s','%s','%s','%s','%s',%d,'%s','%s','%s','%s','%s','%s','%s')",
        timestamp,
        clickhouse_quote(from_domain), clickhouse_quote(mime_domain), ip_str, score,
        nrcpts, task:get_size(), whitelist, bayes, fuzzy, fann,
        dkim, dmarc, nurls, task:get_metric_action('default'),
        clickhouse_quote(from_user), clickhouse_quote(mime_user),
        clickhouse_quote(rcpt_user), clickhouse_quote(rcpt_domain),
        clickhouse_quote(list_id), task:get_digest())
  table.insert(rows, elt)

  if settings['from_map'] and dkim == 'allow' then
    -- Use dkim
    local das = task:get_symbol(settings['dkim_allow_symbols'][1])
    if ((das or E)[1] or E).options then
      for _,dkim_domain in ipairs(das[1]['options']) do
        local specific = settings.from_map:get_key(dkim_domain)
        if specific then
          if not specific_rows[specific] then
            local first = clickhouse_main_row(specific)
            specific_rows[specific] = {first}
          end
          table.insert(specific_rows[specific], elt)
        end
      end
    end

  end

  -- Attachments step
  local attachments_fnames = {}
  local attachments_ctypes = {}
  local attachments_lengths = {}
  local attachments_digests = {}
  for _,part in ipairs(task:get_parts()) do
    local fname = part:get_filename()

    if fname then
      table.insert(attachments_fnames, string.format("'%s'", clickhouse_quote(fname)))
      local type, subtype = part:get_type()
      table.insert(attachments_ctypes, string.format("'%s/%s'",
        clickhouse_quote(type), clickhouse_quote(subtype)))
      table.insert(attachments_lengths, string.format("%s", tostring(part:get_length())))
      table.insert(attachments_digests, string.format("'%s'", string.sub(part:get_digest(), 1, 16)))
    end
  end

  if #attachments_fnames > 0 then
    elt = string.format("(today(),'%s',[%s],[%s],[%s],[%s])",
      task:get_digest(),
      table.concat(attachments_fnames, ','),
      table.concat(attachments_ctypes, ','),
      table.concat(attachments_lengths, ','),
      table.concat(attachments_digests, ','))
    table.insert(attachment_rows, elt)
  end

  -- Urls step
  local urls_tlds = {}
  local urls_urls = {}
  if task:has_urls(false) then
    for _,u in ipairs(task:get_urls(false)) do
      table.insert(urls_tlds, string.format("'%s'", clickhouse_quote(u:get_tld())))
      if settings['full_urls'] then
        table.insert(urls_urls, string.format("'%s'",
          clickhouse_quote(u:get_text())))
      else
        table.insert(urls_urls, string.format("'%s'",
          clickhouse_quote(u:get_host())))
      end
    end
  end

  if #urls_tlds > 0 then
    elt = string.format("(today(),'%s',[%s],[%s])",
      task:get_digest(),
      table.concat(urls_tlds, ','),
      table.concat(urls_urls, ','))
    table.insert(urls_rows, elt)
  end

  -- Emails step
  local emails = {}
  if task:has_urls(true) then
    for _,u in ipairs(task:get_emails()) do
      table.insert(emails, string.format("'%s'", clickhouse_quote(
          string.format('%s@%s', u:get_user(), u:get_host())
      )))
    end
  end

  if #emails > 0 then
    elt = string.format("(today(),'%s',[%s])",
        task:get_digest(),
        table.concat(emails, ','))
    table.insert(emails_rows, elt)
  end

  -- ASN information
  if settings['asn_table'] then
    local asn, country, ipnet = '--', '--', '--'
    local pool = task:get_mempool()
    ret = pool:get_variable("asn")
    if ret then
      asn = ret
    end
    ret = pool:get_variable("country")
    if ret then
      country = ret:sub(1, 2)
    end
    ret = pool:get_variable("ipnet")
    if ret then
      ipnet = ret
    end
    elt = string.format("(today(),'%s','%s','%s','%s')",
      task:get_digest(),
      clickhouse_quote(asn), clickhouse_quote(country), clickhouse_quote(ipnet))
    table.insert(asn_rows, elt)
  end

  -- Symbols info
  if settings.enable_symbols and settings['symbols_table'] then
    local symbols = task:get_symbols_all()
    local syms_tab = {}
    local scores_tab = {}
    local options_tab = {}

    for _,s in ipairs(symbols) do
      table.insert(syms_tab, string.format("'%s'",
        clickhouse_quote(s.name or '')))
      table.insert(scores_tab, string.format('%.3f', s.score))

      if s.options then
        table.insert(options_tab, string.format("'%s'",
          clickhouse_quote(table.concat(s.options, ','))))
      else
        table.insert(options_tab, "''");
      end
    end

    elt = string.format("(today(),'%s',[%s],[%s],[%s])",
      task:get_digest(),
      table.concat(syms_tab, ','),
      table.concat(scores_tab, ','),
      table.concat(options_tab, ','))

    table.insert(symbols_rows, elt)
  end

  -- Custom data
  for k,rule in pairs(settings.custom_rules) do
    if not custom_rows[k] then custom_rows[k] = {} end
    table.insert(custom_rows[k], rule.get_row(task))
  end

  nrows = nrows + 1

  if nrows > settings['limit'] then
    clickhouse_send_data(task)
    nrows = 0
    rows = {}
    attachment_rows = {}
    urls_rows = {}
    emails_rows = {}
    specific_rows = {}
    asn_rows = {}
    symbols_rows = {}
    custom_rows = {}
    clickhouse_first_row()
  end
end

local function mk_remove_http_cb(upstream, params, ok_cb)
  local function do_remove_http_cb(err_message, code, data, _)
    if code ~= 200 or err_message then
      if not err_message then err_message = data end
      local ip_addr = upstream:get_addr():to_string(true)
      rspamd_logger.errx(rspamd_config, "request failed on clickhouse server %s: %s",
              ip_addr, err_message)
      upstream:fail()
    else
      upstream:ok()
      if (ok_cb) then
        rspamd_logger.debugm(N, rspamd_config, "do_remove_http_cb ok: %s, %s, %s, %s", err_message, code, data, _)
        ok_cb(params.ev_base, params.config, data)
      end
    end
  end
  return do_remove_http_cb
end

local function clickhouse_request(upstream, ok_cb, params)
  rspamd_logger.debugm(N, rspamd_config, "clickhouse_request: %s", params.body)

  params.callback = mk_remove_http_cb(upstream, params, ok_cb)
  params.gzip = settings.use_gzip
  params.mime_type = 'text/plain'
  params.timeout = settings['timeout']
  params.no_ssl_verify = settings.no_ssl_verify
  params.user = settings.user
  params.password = settings.password
  if not params.url then
    local ip_addr = upstream:get_addr():to_string(true)
    params.url = connect_prefix .. ip_addr
  end
  return rspamd_http.request(params)
end

local function do_remove_partition(ev_base, cfg, table_name, partition_id)
  rspamd_logger.debugm(N, rspamd_config, "removing partition %s.%s", table_name, partition_id)
  local upstream = settings.upstream:get_upstream_round_robin()
  local remove_partition_sql = "ALTER TABLE ${table_name} ${remove_method} PARTITION ${partition_id}"
  local remove_method = (settings.retention.method == 'drop') and 'DROP' or 'DETACH'
  local sql_params = {
    ['table_name']     = table_name,
    ['remove_method']  = remove_method,
    ['partition_id']   = partition_id
  }

  local sql = rspamd_lua_utils.template(remove_partition_sql, sql_params)

  local ch_params = {
    body = sql,
    ev_base = ev_base,
    cfg = cfg,
  }

  if not clickhouse_request(upstream, nil, ch_params) then
    rspamd_logger.errx(rspamd_config, "cannot send data to clickhouse server %s: cannot make request",
            settings['server'])
  end
end

local function parse_clickhouse_response(ev_base, cfg, data)
  rspamd_logger.debugm(N, rspamd_config, "got clickhouse response: %s", data)
  if data == nil then
    -- clickhouse returned no data (i.e. empty resultset): exiting
    return
  end
  local function parse_string(s)
    local parser = ucl.parser()
    local res, err = parser:parse_string(s)
    if not res then
      rspamd_logger.errx(rspamd_config, 'Parser error: %s', err)
      return nil
    end
    return parser:get_object()
  end

  -- iterate over rows
  local ch_rows = lua_util.str_split(data, "\n")
  for _, plain_row in pairs(ch_rows) do
    if plain_row and plain_row:len() > 1 then
      local parsed_row = parse_string(plain_row)
      do_remove_partition(rspamd_config, cfg, parsed_row.table, parsed_row.partition)
    end
  end
end


--[[
  nil   - file is not writable, do not perform removal
  0     - it's time to perform removal
  <int> - how many seconds wait until next run
]]
local function get_last_removal_ago()
  local ts_file = string.format('%s/%s', rspamd_paths['DBDIR'], 'clickhouse_retention_run')
  local f, err = io.open(ts_file, 'r')
  local write_file
  local last_ts

  if err then
    rspamd_logger.debugm(N, rspamd_config, 'Failed to open %s: %s', ts_file, err)
  else
    last_ts = tonumber(f:read('*number'))
    f:close()
  end

  local current_ts = os.time()

  if last_ts == nil or (last_ts + settings.retention.period) <= current_ts then
    write_file, err = io.open(ts_file, 'w')
    if err then
      rspamd_logger.errx(rspamd_config, 'Failed to open %s, will not perform retention: %s', ts_file, err)
      return nil
    end

    local res
    res, err = write_file:write(tostring(current_ts))
    if err or res == nil then
      rspamd_logger.errx(rspamd_config, 'Failed to write %s, will not perform retention: %s', ts_file, err)
      return nil
    end
    write_file:close()
    return 0
  end

  return (last_ts + settings.retention.period) - current_ts
end

local function clickhouse_remove_old_partitions(cfg, ev_base)
  local last_time_ago = get_last_removal_ago()
  if last_time_ago == nil then
    rspamd_logger.errx(rspamd_config, "Failed to get last run time. Disabling retention")
    return false
  elseif last_time_ago ~= 0 then
    return last_time_ago
  end

  local upstream = settings.upstream:get_upstream_round_robin()
  local ip_addr = upstream:get_addr():to_string(true)

  local partition_to_remove_sql = "SELECT distinct partition, table FROM system.parts WHERE table in ('${tables}') and max_date <= toDate(now() - interval ${month} month);"

  local table_names = {}
  for table_name,_ in pairs(clickhouse_schema) do
    table.insert(table_names, settings[table_name])
  end
  local tables = table.concat(table_names, "', '")
  local sql_params = {
    tables = tables,
    month  = settings.retention.period_months,
  }
  local sql = rspamd_lua_utils.template(partition_to_remove_sql, sql_params)

  local ch_params = {
    body = sql,
    url  = string.format("%s%s/?default_format=JSONEachRow", connect_prefix, ip_addr),
    ev_base = ev_base,
    config = cfg,
  }
  if not clickhouse_request(upstream, parse_clickhouse_response, ch_params) then
    rspamd_logger.errx(rspamd_config, "cannot send data to clickhouse server %s: cannot make request",
            settings['server'])
  end

  -- settings.retention.period is added on initialisation, see below
  return settings.retention.period
end

local opts = rspamd_config:get_all_opt('clickhouse')
if opts then
    for k,v in pairs(opts) do
      if k == 'custom_rules' then
        if not v[1] then
          v = {v}
        end

        for i,rule in ipairs(v) do
          if rule.schema and rule.first_row and rule.get_row then
            local first_row, get_row
            local loadstring = loadstring or load
            local ret, res_or_err = pcall(loadstring(rule.first_row))

            if not ret or type(res_or_err) ~= 'function' then
              rspamd_logger.errx(rspamd_config, 'invalid first_row (%s) - must be a function',
                  res_or_err)
            else
              first_row = res_or_err
            end

            ret, res_or_err = pcall(loadstring(rule.get_row))

            if not ret or type(res_or_err) ~= 'function' then
              rspamd_logger.errx(rspamd_config, 'invalid get_row (%s) - must be a function',
                  res_or_err)
            else
              get_row = res_or_err
            end

            if first_row and get_row then
              local name = rule.name or tostring(i)
              settings.custom_rules[name] = {
                schema = rule.schema,
                first_row = first_row,
                get_row = get_row,
              }
            end
          else
            rspamd_logger.errx(rspamd_config, 'custom rule has no required attributes: schema, first_row and get_row')
          end
        end
      else
        settings[k] = v
      end
    end

    if not settings['server'] and not settings['servers'] then
      rspamd_logger.infox(rspamd_config, 'no servers are specified, disabling module')
      rspamd_lua_utils.disable_module(N, "config")
    else
      settings['from_map'] = rspamd_map_add('clickhouse', 'from_tables',
        'regexp', 'clickhouse specific domains')
      if settings.use_https then
        connect_prefix = 'https://'
      end

      settings.upstream = upstream_list.create(rspamd_config,
        settings['server'] or settings['servers'], 8123)

      if not settings.upstream then
        rspamd_logger.errx(rspamd_config, 'cannot parse clickhouse address: %s',
            settings['server'] or settings['servers'])
        rspamd_lua_utils.disable_module(N, "config")
        return
      end


      clickhouse_first_row()
      rspamd_config:register_symbol({
        name = 'CLICKHOUSE_COLLECT',
        type = 'idempotent',
        callback = clickhouse_collect,
        priority = 10,
        flags = 'empty',
      })
      rspamd_config:register_finish_script(function(task)
        if nrows > 0 then
          clickhouse_send_data(task)
        end
      end)
      -- Create tables on load
      rspamd_config:add_on_load(function(cfg, ev_base, worker)
        if worker:is_primary_controller() then
          local upstreams = settings.upstream:all_upstreams()

          for _,up in ipairs(upstreams) do
            local ip_addr = up:get_addr():to_string(true)

            local function send_req(elt, sql)
              local function http_cb(err_message, code, data, _)
                if code ~= 200 or err_message then
                  if not err_message then err_message = data end
                  rspamd_logger.errx(rspamd_config, "cannot create table %s in clickhouse server %s: %s",
                      elt, ip_addr, err_message)
                  up:fail()
                else
                  up:ok()
                end
              end

              if not rspamd_http.request({
                ev_base = ev_base,
                config = cfg,
                url = connect_prefix .. ip_addr,
                body = sql,
                callback = http_cb,
                mime_type = 'text/plain',
                timeout = settings['timeout'],
                no_ssl_verify = settings.no_ssl_verify,
                user = settings.user,
                password = settings.password,
              }) then
                rspamd_logger.errx(rspamd_config, "cannot create table %s in clickhouse server %s: cannot make request",
                    elt, ip_addr)
              end
            end

            for tab,sql in pairs(clickhouse_schema) do
              send_req(tab, rspamd_lua_utils.template(sql, settings))
            end

            for k,rule in pairs(settings.custom_rules) do
              if rule.schema then
                send_req(k, rspamd_lua_utils.template(rule.schema, settings))
              end
            end
          end

          if settings.retention.enable and settings.retention.method ~= 'drop' and settings.retention.method ~= 'detach' then
            rspamd_logger.errx(rspamd_config, "retention.method should be either 'drop' or 'detach' (now: %s). Disabling retention",
                    settings.retention.method)
            settings.retention.enable = false
          end
          if settings.retention.enable and settings.retention.period_months < 1 or settings.retention.period_months > 1000 then
            rspamd_logger.errx(rspamd_config, "please, set retention.period_months between 1 and 1000 (now: %s). Disabling retention",
                    settings.retention.period_months)
            settings.retention.enable = false
          end
          local period = lua_util.parse_time_interval(settings.retention.run_every)
          if settings.retention.enable and period == nil then
            rspamd_logger.errx(rspamd_config, "invalid value for retention.run_every (%s). Disabling retention",
                    settings.retention.run_every)
            settings.retention.enable = false
          end

          if settings.retention.enable then
            settings.retention.period = period
            rspamd_logger.infox(rspamd_config, "retention will be performed each %s seconds for %s month with method %s",
                    period, settings.retention.period_months, settings.retention.method)
            rspamd_config:add_periodic(ev_base, 0, clickhouse_remove_old_partitions, false)
          end
        end
      end)
    end
end
