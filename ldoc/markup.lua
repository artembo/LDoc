--------------
-- Handling markup transformation.
-- Currently just does Markdown, but this is intended to
-- be the general module for managing other formats as well.

local doc = require 'ldoc.doc'
local utils = require 'pl.utils'
local stringx = require 'pl.stringx'
local prettify = require 'ldoc.prettify'
local quit, concat, lstrip = utils.quit, table.concat, stringx.lstrip
local markup = {}

local backtick_references

-- inline <references> use same lookup as @see
local function resolve_inline_references (ldoc, txt, item, plain)
   local res = (txt:gsub('@{([^}]-)}',function (name)
      if name:match '^\\' then return '@{'..name:sub(2)..'}' end
      local qname,label = utils.splitv(name,'%s*|')
      if not qname then
         qname = name
      end
      local ref,err = markup.process_reference(qname)
      if not ref then
         err = err .. ' ' .. qname
         if item and item.warning then item:warning(err)
         else
           io.stderr:write('nofile error: ',err,'\n')
         end
         return '???'
      end
      if not label then
         label = ref.label
      end
      if not plain and label then -- a nastiness with markdown.lua and underscores
         label = label:gsub('_','\\_')
      end
      local html = ldoc.href(ref) or '#'
      label = label or qname
      local res = ('<a href="%s">%s</a>'):format(html,label)
      return res
   end))
   if backtick_references then
      res  = res:gsub('`([^`]+)`',function(name)
         local ref,err = markup.process_reference(name)
         if ref then
            return ('<a href="%s">%s</a> '):format(ldoc.href(ref),name)
         else
            return '<code>'..name..'</code>'
         end
      end)
   end
   return res
end

-- for readme text, the idea here is to create module sections at ## so that
-- they can appear in the contents list as a ToC.
function markup.add_sections(F, txt)
   local sections, L, first = {}, 1, true
   local title_pat
   local lstrip = stringx.lstrip
   for line in stringx.lines(txt) do
      if first then
         local level,header = line:match '^(#+)%s*(.+)'
         if level then
            level = level .. '#'
         else
            level = '##'
         end
         title_pat = '^'..level..'([^#]%s*.+)'
         title_pat = lstrip(title_pat)
         first = false
         F.display_name = header
      end
      local title = line:match (title_pat)
      if title then
         -- Markdown allows trailing '#'...
         title = title:gsub('%s*#+$','')
         sections[L] = F:add_document_section(lstrip(title))
      end
      L = L + 1
   end
   F.sections = sections
   return txt
end

local function indent_line (line)
   line = line:gsub('\t','    ') -- support for barbarians ;)
   local indent = #line:match '^%s*'
   return indent,line
end

local function blank (line)
   return not line:find '%S'
end

local global_context, local_context

-- before we pass Markdown documents to markdown/discount, we need to do three things:
-- - resolve any @{refs} and (optionally) `refs`
-- - any @lookup directives that set local context for ref lookup
-- - insert any section ids which were generated by add_sections above
-- - prettify any code blocks

local function process_multiline_markdown(ldoc, txt, F)
   local res, L, append = {}, 0, table.insert
   local filename = F.filename
   local err_item = {
      warning = function (self,msg)
         io.stderr:write(filename..':'..L..': '..msg,'\n')
      end
   }
   local get = stringx.lines(txt)
   local getline = function()
      L = L + 1
      return get()
   end
   local function pretty_code (code, lang)
      code = concat(code,'\n')
      if code ~= '' then
         local err
         -- If we omit the following '\n', a '--' (or '//') comment on the
         -- last line won't be recognized.
         code, err = prettify.code(lang,filename,code..'\n',L,false)
         append(res,'<pre>')
         append(res, code)
         append(res,'</pre>')
      else
         append(res,code)
      end
   end
   local indent,start_indent
   local_context = nil
   local line = getline()
   while line do
      local name = line:match '^@lookup%s+(%S+)'
      if name then
         local_context = name .. '.'
         line = getline()
      end
      local fence = line:match '^```(.*)'
      if fence then
         local plain = fence==''
         line = getline()
         local code = {}
         while not line:match '^```' do
            if not plain then
               append(code, line)
            else
               append(res, '     '..line)
            end
            line = getline()
         end
         pretty_code (code,fence)
         line = getline() -- skip fence
      end
      indent, line = indent_line(line)
      if indent >= 4 then -- indented code block
         local code = {}
         local plain
         while indent >= 4 or blank(line) do
            if not start_indent then
               start_indent = indent
               if line:match '^%s*@plain%s*$' then
                  plain = true
                  line = getline()
               end
            end
            if not plain then
               append(code,line:sub(start_indent + 1))
            else
               append(res,line)
            end
            line = getline()
            if line == nil then break end
            indent, line = indent_line(line)
         end
         start_indent = nil
         while #code > 1 and blank(code[#code]) do  -- trim blank lines.
           table.remove(code)
         end
         pretty_code (code,'lua')
      else
         local section = F.sections[L]
         if section then
            append(res,('<a name="%s"></a>'):format(section))
         end
         line = resolve_inline_references(ldoc, line, err_item)
         append(res,line)
         line = getline()
      end
   end
   res = concat(res,'\n')
   return res
end


-- Handle markdown formatters
-- Try to get the one the user has asked for, but if it's not available,
-- try all the others we know about.  If they don't work, fall back to text.

local function generic_formatter(format)
   local ok, f = pcall(require, format)
   return ok and f
end


local formatters =
{
   markdown = function(format)
      local ok, markdown = pcall(require, 'markdown')
      if not ok then
         print('format: using built-in markdown')
         ok, markdown = pcall(require, 'ldoc.markdown')
      end
      return ok and markdown
   end,
   discount = generic_formatter,
   lunamark = function(format)
      local ok, lunamark = pcall(require, format)
      if ok then
         local writer = lunamark.writer.html.new()
         local parse = lunamark.reader.markdown.new(writer,
                                                    { smart = true })
         return function(text) return parse(text) end
      end
   end
}


local function get_formatter(format)
   local formatter = (formatters[format] or generic_formatter)(format)
   if formatter then return formatter end

   for name, f in pairs(formatters) do
      formatter = f(name)
      if formatter then
         print('format: '..format..' not found, using '..name)
         return formatter
      end
   end
end

local function text_processor(ldoc)
   return function(txt,item)
      if txt == nil then return '' end
      -- hack to separate paragraphs with blank lines
      txt = txt:gsub('\n\n','\n<p>')
      return resolve_inline_references(ldoc, txt, item, true)
   end
end

local plain_processor

local function markdown_processor(ldoc, formatter)
   return function (txt,item,plain)
      if txt == nil then return '' end
      if plain then
         if not plain_processor then
            plain_processor = text_processor(ldoc)
         end
         return plain_processor(txt,item)
      end
      if utils.is_type(item,doc.File) then
         txt = process_multiline_markdown(ldoc, txt, item)
      else
         txt = resolve_inline_references(ldoc, txt, item)
      end
      txt = formatter(txt)
      -- We will add our own paragraph tags, if needed.
      return (txt:gsub('^%s*<p>(.+)</p>%s*$','%1'))
   end
end

local function get_processor(ldoc, format)
   if format == 'plain' then return text_processor(ldoc) end

   local formatter = get_formatter(format)
   if formatter then
      markup.plain = false
      return markdown_processor(ldoc, formatter)
   end

   print('format: '..format..' not found, falling back to text')
   return text_processor(ldoc)
end


function markup.create (ldoc, format, pretty)
   local processor
   markup.plain = true
   if format == 'backtick' then
      ldoc.backtick_references = true
      format = 'plain'
   end
   backtick_references = ldoc.backtick_references
   global_context = ldoc.package and ldoc.package .. '.'
   prettify.set_prettifier(pretty)

   markup.process_reference = function(name,istype)
      if local_context == 'none.' and not name:match '%.' then
         return nil,'not found'
      end
      local mod = ldoc.single or ldoc.module or ldoc.modules[1]
      local ref,err = mod:process_see_reference(name, ldoc.modules, istype)
      if ref then return ref end
      if global_context then
         local qname = global_context .. name
         ref = mod:process_see_reference(qname, ldoc.modules, istype)
         if ref then return ref end
      end
      if local_context then
         local qname = local_context .. name
         ref = mod:process_see_reference(qname, ldoc.modules, istype)
         if ref then return ref end
      end
      -- note that we'll return the original error!
      return ref,err
   end

   markup.href = function(ref)
      return ldoc.href(ref)
   end

   processor = get_processor(ldoc, format)
   if not markup.plain and backtick_references == nil then
      backtick_references = true
   end

   markup.resolve_inline_references = function(txt, errfn)
      return resolve_inline_references(ldoc, txt, errfn, markup.plain)
   end
   markup.processor = processor
   prettify.resolve_inline_references = function(txt, errfn)
      return resolve_inline_references(ldoc, txt, errfn, true)
   end
   return processor
end


return markup
