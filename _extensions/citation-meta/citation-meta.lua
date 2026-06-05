-- citation-meta.lua
-- Emits academic SEO metadata for Quarto HTML output:
--   * Google Scholar citation_* meta tags (only on status: published pages)
--   * JSON-LD ScholarlyArticle structured data (only on status: published)
--   * <meta name="description"> built from the first sentence of the
--     Abstract section, overriding the venue-label description
--   * <link rel="canonical"> on every page
--
-- The filter reads the existing frontmatter (title / author / date /
-- venue / volume / pages / status) so per-paper .qmd files don't need
-- to change. DOI and PDF URL are pulled from inline body links
-- "[DOI](https://doi.org/…)" and "[PDF](…)" when present.

local stringify = pandoc.utils.stringify

local SITE_URL = "https://contefranz.github.io"

-- ---------- helpers ----------

local function html_escape(s)
  s = tostring(s or "")
  return (s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;"))
end

local function json_escape(s)
  s = tostring(s or "")
  return (s:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n"))
end

local function emit(content)
  quarto.doc.include_text("in-header", content)
end

local function get_str(meta, key)
  if meta[key] == nil then return nil end
  local s = stringify(meta[key])
  if s == "" then return nil end
  return s
end

local function get_list(meta, key)
  local m = meta[key]
  if not m then return {} end
  -- Pandoc Lua: a YAML list comes through as a List-typed table with
  -- 1-based numeric indices. The older `m.t == "MetaList"` check is
  -- unreliable across Pandoc versions; check for numeric indexability.
  if type(m) == "table" and m[1] ~= nil then
    local out = {}
    for _, item in ipairs(m) do
      table.insert(out, stringify(item))
    end
    return out
  end
  local s = stringify(m)
  if s == "" then return {} end
  return { s }
end

-- "Miles Gietzmann" -> "Gietzmann, Miles"; "Craig M. Lewis" -> "Lewis, Craig M."
-- Already "Last, First" returned unchanged.
local function to_citation_author(name)
  if name:find(",") then return name end
  local last = name:match("(%S+)$")
  local rest = name:match("^(.-)%s+%S+$")
  if last and rest then
    return last .. ", " .. rest
  end
  return name
end

local function first_sentence(text, max_len)
  max_len = max_len or 160
  text = text:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
  -- Prefer ending at the first ". " / "! " / "? "
  local s = text:match("^(.-[%.!?])%s")
  if not s then s = text end
  if #s > max_len then
    -- Trim to nearest space below max_len
    local cut = s:sub(1, max_len)
    local last_space = cut:find("%s%S*$")
    if last_space then cut = cut:sub(1, last_space - 1) end
    s = cut .. "…"
  end
  return s
end

-- Walk top-level blocks. After the first "## Abstract" heading, capture
-- the next Para's plain text.
local function extract_abstract(blocks)
  local found = false
  for _, b in ipairs(blocks) do
    if b.t == "Header" and b.level == 2 then
      local h = stringify(b):lower()
      if h:find("abstract", 1, true) then
        found = true
      elseif found then
        return nil  -- next h2 reached without finding a paragraph
      end
    elseif found and b.t == "Para" then
      return stringify(b)
    end
  end
  return nil
end

-- Find the URL of the first [LABEL](...) link in early body content where
-- the label matches the pattern (lowercased).
local function extract_link_url(blocks, label_pattern)
  for _, b in ipairs(blocks) do
    if (b.t == "Para" or b.t == "Plain") and b.content then
      for _, inline in ipairs(b.content) do
        if inline.t == "Link" then
          local label = stringify(inline.content):lower()
          if label:find(label_pattern) then
            return inline.target
          end
        end
      end
    end
    -- Stop scanning once we leave the lead block
    if b.t == "Header" then break end
  end
  return nil
end

local function canonical_for_input(input_path)
  if not input_path then return nil end
  local project_dir = os.getenv("QUARTO_PROJECT_DIR")
  local rel = input_path
  if project_dir and #project_dir > 0 and input_path:sub(1, #project_dir) == project_dir then
    rel = input_path:sub(#project_dir + 2)
  else
    -- Fall back to basename stripping
    rel = input_path:match("([^/]+)$") or input_path
  end
  rel = rel:gsub("%.qmd$", ".html"):gsub("%.md$", ".html"):gsub("%.ipynb$", ".html")
  rel = rel:gsub("^index%.html$", ""):gsub("/index%.html$", "/")
  return SITE_URL .. "/" .. rel
end

-- ---------- main pass ----------

function Pandoc(doc)
  if not (quarto and quarto.doc and quarto.doc.is_format("html:js")) then
    return doc
  end

  local meta = doc.meta
  local blocks = doc.blocks

  -- 1) Better <meta name="description"> from the abstract's first
  --    sentence. This is the tag Google uses for search snippets, the
  --    single highest-leverage description. Overriding `meta.description`
  --    here makes Quarto emit the abstract sentence instead of the
  --    venue-label `description` from the source frontmatter.
  --
  --    Note: Quarto's website OG generator caches the original
  --    frontmatter description before per-document filters run, so
  --    `og:description` and `twitter:description` still show the venue
  --    label. That's an acceptable social-card subtitle, so we don't
  --    fight it. The listing on publications.qmd also keeps the venue
  --    label (it reads source frontmatter, not modified meta).
  local abstract = extract_abstract(blocks)
  local meta_description = nil
  if abstract then
    meta_description = first_sentence(abstract, 160)
    meta.description = pandoc.MetaInlines({ pandoc.Str(meta_description) })
  end

  -- 2) Canonical URL on every page.
  local canonical = canonical_for_input(quarto.doc.input_file)
  if canonical then
    emit(string.format('<link rel="canonical" href="%s">', html_escape(canonical)))
  end

  -- 3) Scholar citation_* tags + ScholarlyArticle JSON-LD on published papers.
  local status = get_str(meta, "status")
  if status ~= "published" then
    return doc
  end

  local title = get_str(meta, "title")
  local authors = get_list(meta, "author")
  local date = get_str(meta, "date")
  -- Year may appear at the start (ISO "2026-03-09") or anywhere (Quarto's
  -- localized "March 9, 2026"). Match any 4-digit year between 1900–2099.
  local year = nil
  if date then
    year = date:match("^(%d%d%d%d)") or date:match("(19%d%d)") or date:match("(20%d%d)")
  end
  local venue = get_str(meta, "venue")
  local volume = get_str(meta, "volume")
  local pages = get_str(meta, "pages")
  local issue = get_str(meta, "issue")

  if title then
    emit(string.format('<meta name="citation_title" content="%s">', html_escape(title)))
  end

  local citation_authors = {}
  for _, a in ipairs(authors) do
    local ca = to_citation_author(a)
    table.insert(citation_authors, ca)
    emit(string.format('<meta name="citation_author" content="%s">', html_escape(ca)))
  end

  if year then
    emit(string.format('<meta name="citation_publication_date" content="%s">', year))
  end
  if venue then
    emit(string.format('<meta name="citation_journal_title" content="%s">', html_escape(venue)))
  end
  if volume then
    emit(string.format('<meta name="citation_volume" content="%s">', html_escape(volume)))
  end
  if issue then
    emit(string.format('<meta name="citation_issue" content="%s">', html_escape(issue)))
  end

  local first_p, last_p
  if pages then
    -- Normalize en-dash (U+2013) and em-dash (U+2014) to ASCII hyphen.
    -- Lua patterns are byte-oriented; UTF-8 multi-byte chars don't play
    -- well inside character classes.
    local pages_norm = pages:gsub("\xE2\x80\x93", "-"):gsub("\xE2\x80\x94", "-")
    first_p, last_p = pages_norm:match("(%d+)%s*%-%s*(%d+)")
    if not first_p then first_p = pages_norm:match("(%d+)") end
    if first_p then
      emit(string.format('<meta name="citation_firstpage" content="%s">', first_p))
    end
    if last_p then
      emit(string.format('<meta name="citation_lastpage" content="%s">', last_p))
    end
  end

  local doi = get_str(meta, "doi")
  if not doi then
    local doi_url = extract_link_url(blocks, "doi")
    if doi_url then
      doi = doi_url:match("doi%.org/(.+)$") or doi_url
    end
  end
  if doi then
    emit(string.format('<meta name="citation_doi" content="%s">', html_escape(doi)))
  end

  local pdf_url = get_str(meta, "pdf")
  if not pdf_url then
    pdf_url = extract_link_url(blocks, "^pdf$")
  end
  if pdf_url then
    emit(string.format('<meta name="citation_pdf_url" content="%s">', html_escape(pdf_url)))
  end

  -- JSON-LD ScholarlyArticle
  local lines = {
    '<script type="application/ld+json">',
    '{',
    '  "@context": "https://schema.org",',
    '  "@type": "ScholarlyArticle",',
  }
  local function push(line) table.insert(lines, line) end

  if title then push('  "name": "' .. json_escape(title) .. '",') end

  if #citation_authors > 0 then
    local auth_objs = {}
    for _, ca in ipairs(citation_authors) do
      local last, first = ca:match("^([^,]+),%s*(.+)$")
      local display
      if first and last then
        display = first .. " " .. last
      else
        display = ca
      end
      table.insert(auth_objs,
        '{"@type": "Person", "name": "' .. json_escape(display) .. '"}')
    end
    push('  "author": [' .. table.concat(auth_objs, ", ") .. '],')
  end

  if venue then
    push('  "isPartOf": {"@type": "Periodical", "name": "' ..
      json_escape(venue) .. '"},')
  end
  if year then push('  "datePublished": "' .. year .. '",') end
  if doi then
    push('  "identifier": "doi:' .. json_escape(doi) .. '",')
    push('  "sameAs": "https://doi.org/' .. json_escape(doi) .. '",')
  end
  if abstract then
    local short = first_sentence(abstract, 500)
    push('  "abstract": "' .. json_escape(short) .. '",')
  end
  if canonical then
    push('  "url": "' .. json_escape(canonical) .. '",')
  end

  -- Strip trailing comma on the last data line
  lines[#lines] = lines[#lines]:gsub(",%s*$", "")
  push('}')
  push('</script>')
  emit(table.concat(lines, "\n"))

  doc.meta = meta
  return doc
end
