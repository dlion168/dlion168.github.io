# frozen_string_literal: true
#
# scholar_meta.rb — inject Highwire Press citation_* meta tags and schema.org
# JSON-LD into the <head> of jekyll-scholar bibliography detail pages, plus a
# Person + sameAs block on the homepage.
#
# WHY A PLUGIN INSTEAD OF AN _includes OVERRIDE
# ---------------------------------------------
# al-folio v1.x moved _includes/head.liquid into the al_folio_core gem. Adding
# an include line to <head> therefore means shadowing a gem-owned file, which
# you then have to re-audit on every theme upgrade
# (`bundle exec al-folio upgrade overrides audit`). This plugin appends to the
# rendered HTML instead, so it never conflicts with the theme and survives
# upgrades untouched. Requires building with GitHub Actions (al-folio's default
# workflow), not the legacy github-pages gem — custom plugins are allowed there.
#
# WHAT GOOGLE SCHOLAR REQUIRES (https://scholar.google.com/intl/en/scholar/inclusion.html)
#   - one article per HTML file  -> jekyll-scholar's `details_dir` gives us that
#   - one citation_author tag per author; never the deprecated citation_authors
#   - citation_journal_title and citation_conference_title are mutually exclusive
#   - citation_pdf_url should always be present
#
# SAFE BY CONSTRUCTION: every hook body is wrapped in a rescue that logs a
# warning and leaves the page untouched, so a malformed BibTeX entry can never
# break your build.

require "json"
require "cgi"

module ScholarMeta
  SITE_PERSON_ID = "/#person"

  module_function

  # jekyll-scholar hands back BibTeX::Value objects, not Strings, and BibTeX
  # keeps LaTeX escaping ("21.21\\%", "R\\&D"). Two consequences if you skip this:
  #   1. a non-String value can bypass JSON escaping and emit invalid JSON-LD
  #      (observed on rittergutierrez2025astarntu, whose abstract contains "\\%")
  #   2. readers and crawlers see "21.21\\%" instead of "21.21%"
  # So: force to String, unescape LaTeX, collapse whitespace. Always.
  LATEX_ESCAPES = { "\\%" => "%", "\\&" => "&", "\\_" => "_", "\\$" => "$",
                    "\\#" => "#", "\\{" => "{", "\\}" => "}" }.freeze

  def clean(value)
    s = value.to_s.dup
    LATEX_ESCAPES.each { |from, to| s.gsub!(from, to) }
    s.gsub(/\s+/, " ").strip
  end

  def esc(str)
    CGI.escapeHTML(clean(str))
  end

  # bibtex-ruby LaTeX-decodes "2053--2057" into an en dash before we ever see it,
  # so normalize every dash form back to a single separator.
  def split_pages(pages)
    return [nil, nil] if pages.nil? || pages.to_s.strip.empty?
    parts = clean(pages).gsub(/[‒–—―]/, "-").split(/-+/).map(&:strip).reject(&:empty?)
    [parts[0], parts[1]]
  end

  def authors_of(entry)
    raw = clean(entry["author"])
    raw.split(/\s+and\s+/).map { |a| a.strip }.reject(&:empty?)
  end

  def meta_tags(entry, page_url, site_url)
    out = []
    out << %(<meta name="citation_title" content="#{esc(entry['title'])}">)
    authors_of(entry).each { |a| out << %(<meta name="citation_author" content="#{esc(a)}">) }

    if entry["booktitle"] && !entry["booktitle"].to_s.empty?
      out << %(<meta name="citation_conference_title" content="#{esc(entry['booktitle'])}">)
    elsif entry["journal"] && !entry["journal"].to_s.empty?
      out << %(<meta name="citation_journal_title" content="#{esc(entry['journal'])}">)
    end

    out << %(<meta name="citation_publication_date" content="#{esc(entry['year'])}">)

    first, last = split_pages(entry["pages"])
    out << %(<meta name="citation_firstpage" content="#{esc(first)}">) if first
    out << %(<meta name="citation_lastpage" content="#{esc(last)}">) if last

    out << %(<meta name="citation_doi" content="#{esc(entry['doi'])}">) if entry["doi"]

    if entry["arxiv"] && !entry["arxiv"].to_s.empty?
      arx = clean(entry["arxiv"])
      out << %(<meta name="citation_arxiv_id" content="#{esc(arx)}">)
      out << %(<meta name="citation_pdf_url" content="https://arxiv.org/pdf/#{esc(arx)}">)
    elsif entry["pdf"] && !entry["pdf"].to_s.empty?
      out << %(<meta name="citation_pdf_url" content="#{site_url}/assets/pdf/#{esc(entry['pdf'])}">)
    end

    out << %(<meta name="citation_abstract" content="#{esc(entry['abstract'])}">) if entry["abstract"]
    out << %(<meta name="citation_language" content="en">)
    out
  end

  def article_jsonld(entry, page_url, site_url)
    canonical = "#{site_url}#{page_url}"
    ids, same = [], []
    if entry["doi"] && !entry["doi"].to_s.empty?
      ids  << { "@type" => "PropertyValue", "propertyID" => "DOI", "value" => clean(entry["doi"]) }
      same << "https://doi.org/#{clean(entry['doi'])}"
    end
    if entry["arxiv"] && !entry["arxiv"].to_s.empty?
      ids  << { "@type" => "PropertyValue", "propertyID" => "arXiv", "value" => "arXiv:#{clean(entry['arxiv'])}" }
      same << "https://arxiv.org/abs/#{clean(entry['arxiv'])}"
    end

    people = authors_of(entry).map do |a|
      h = { "@type" => "Person", "name" => clean(a) }
      h["@id"] = "#{site_url}#{SITE_PERSON_ID}" if a.include?("Yi-Cheng Lin")
      h
    end

    doc = {
      "@context"      => "https://schema.org",
      "@type"         => "ScholarlyArticle",
      "@id"           => canonical,
      "url"           => canonical,
      "name"          => clean(entry["title"]),
      "headline"      => clean(entry["title"]),
      "author"        => people,
      "datePublished" => clean(entry["year"]),
      "inLanguage"    => "en"
    }
    doc["abstract"] = clean(entry["abstract"]) if entry["abstract"]
    if entry["booktitle"] && !entry["booktitle"].to_s.empty?
      doc["isPartOf"] = { "@type" => "PublicationEvent", "name" => clean(entry["booktitle"]) }
    elsif entry["journal"] && !entry["journal"].to_s.empty?
      doc["isPartOf"] = { "@type" => "Periodical", "name" => clean(entry["journal"]) }
    end
    doc["identifier"]     = ids  unless ids.empty?
    doc["sameAs"]         = same unless same.empty?
    doc["codeRepository"] = clean(entry["code"]) if entry["code"] && !entry["code"].to_s.empty?

    %(<script type="application/ld+json">\n#{JSON.pretty_generate(doc)}\n</script>)
  end

  def person_jsonld(site)
    cfg   = site.config
    soc   = site.data["socials"] || {}
    root  = cfg["url"].to_s + cfg["baseurl"].to_s

    same = []
    same << "https://orcid.org/#{soc['orcid_id']}"                                     if soc["orcid_id"]
    same << "https://scholar.google.com/citations?user=#{soc['scholar_userid']}"       if soc["scholar_userid"]
    same << "https://www.semanticscholar.org/author/Yi-Cheng-Lin/#{soc['semanticscholar_id']}"      if soc["semanticscholar_id"]
    same << "https://arxiv.org/a/#{soc['arxiv_id']}"                                   if soc["arxiv_id"]
    same << "https://openalex.org/#{soc['openalex_id']}"                               if soc["openalex_id"]
    same << soc["dblp_url"].to_s                                                       if soc["dblp_url"]
    same << "https://github.com/#{soc['github_username']}"                             if soc["github_username"]
    # Hugging Face is a jekyll-socials "custom social" (a Hash), not a plain key.
    hf = soc["huggingface"]
    same << hf["url"].to_s if hf.is_a?(Hash) && hf["url"]
    same << "https://huggingface.co/#{soc['huggingface_id']}" if soc["huggingface_id"]
    same << "https://www.linkedin.com/in/#{soc['linkedin_username']}"                  if soc["linkedin_username"]

    doc = {
      "@context"      => "https://schema.org",
      "@type"         => "Person",
      "@id"           => "#{root}#{SITE_PERSON_ID}",
      "name"          => "#{cfg['first_name']} #{cfg['last_name']}".strip,
      "givenName"     => cfg["first_name"].to_s,
      "familyName"    => cfg["last_name"].to_s,
      "alternateName" => ["Yi Cheng Lin", "Y.-C. Lin", "林羿成"],
      "url"           => "#{root}/",
      "image"         => "#{root}/assets/img/prof_pic.jpg",
      "description"   => cfg["description"].to_s.gsub(/\s+/, " ").strip,
      "knowsAbout"    => [
        "Speech Emotion Recognition",
        "Fairness in Speech Technology",
        "Social Bias in Speech Models",
        "Large Audio-Language Models",
        "Self-Supervised Speech Representation Learning",
        "Neural Audio Codecs",
        "Speech Quality Assessment"
      ],
      "affiliation"   => {
        "@type" => "CollegeOrUniversity",
        "name"  => "National Taiwan University",
        "url"   => "https://www.ntu.edu.tw/"
      }
    }
    doc["email"] = "mailto:#{soc['email']}" if soc["email"]
    if soc["orcid_id"]
      doc["identifier"] = { "@type" => "PropertyValue", "propertyID" => "ORCID",
                            "value" => "https://orcid.org/#{soc['orcid_id']}" }
    end
    doc["sameAs"] = same unless same.empty?

    %(<script type="application/ld+json">\n#{JSON.pretty_generate(doc)}\n</script>)
  end


  # Icons on the publication buttons. al-folio renders every button as a bare
  # <a class="btn btn-sm z-depth-0">DOI|arXiv|Code</a> with no per-type class, so
  # the only hook is the href. Font Awesome 7 and academicons are already loaded
  # by the theme; we reuse their glyphs rather than shipping our own.
  #
  # Done as injected CSS instead of shadowing the gem's _layouts/bib.liquid, for
  # the same reason the meta tags are injected here: overriding a gem file means
  # re-auditing it on every theme upgrade.
  # NOTE: single-quoted heredoc. With <<~CSS, Ruby eats the CSS escapes -
  # \e974 becomes a literal ESC byte and \f09b a form feed, so the glyphs
  # silently render as nothing.
  BUTTON_ICON_CSS = <<~'CSS'.freeze
    <style>
      a.btn[href*="github.com"]::before,
      a.btn[href^="https://doi.org/"]::before,
      a.btn[href*="arxiv.org/abs"]::before {
        margin-right: 0.4em;
        font-style: normal;
        font-variant: normal;
        text-rendering: auto;
        -webkit-font-smoothing: antialiased;
      }
      a.btn[href*="github.com"]::before {
        font-family: var(--fa-family-brands, "Font Awesome 7 Brands");
        font-weight: 400;
        content: "\f09b";
      }
      a.btn[href^="https://doi.org/"]::before {
        font-family: "Academicons";
        content: "\e97e";
      }
      a.btn[href*="arxiv.org/abs"]::before {
        font-family: "Academicons";
        content: "\e974";
      }
      /* Hugging Face has no glyph in either icon font, so use their favicon. */
      a.btn[href*="huggingface.co"]::before {
        content: "";
        display: inline-block;
        width: 1em;
        height: 1em;
        margin-right: 0.4em;
        vertical-align: -0.15em;
        background: url("https://huggingface.co/favicon.ico") no-repeat center / contain;
      }
    </style>
  CSS

  def inject(html, payload)
    return html unless html.include?("</head>")
    html.sub("</head>", "#{payload}\n</head>")
  end

  # al-folio has no bibtex field for datasets, so a Hugging Face dataset rides in
  # on `website` and the button would read "Website". Relabel it here rather than
  # shadowing the gem's bib.liquid.
  def relabel_dataset_buttons(html)
    html.gsub(%r{(<a href="[^"]*huggingface\.co/datasets/[^"]*"[^>]*class="[^"]*btn[^"]*"[^>]*>)Website(</a>)}) do
      "#{Regexp.last_match(1)}Dataset#{Regexp.last_match(2)}"
    end
  end
end

Jekyll::Hooks.register :pages, :post_render do |page|
  begin
    site  = page.site
    root  = site.config["url"].to_s + site.config["baseurl"].to_s
    entry = page.data["entry"]

    if entry
      payload = ScholarMeta.meta_tags(entry, page.url, root).join("\n") + "\n" +
                ScholarMeta.article_jsonld(entry, page.url, root)
      page.output = ScholarMeta.inject(page.output, payload)
    elsif page.url == "/" || page.url == "/index.html"
      page.output = ScholarMeta.inject(page.output, ScholarMeta.person_jsonld(site))
    end

    # Publication buttons appear on detail pages, /publications/ and the home page.
    if entry || ["/", "/index.html", "/publications/"].include?(page.url)
      page.output = ScholarMeta.inject(page.output, ScholarMeta::BUTTON_ICON_CSS)
      page.output = ScholarMeta.relabel_dataset_buttons(page.output)
    end
  rescue StandardError => e
    Jekyll.logger.warn "ScholarMeta:", "skipped #{page.url} — #{e.class}: #{e.message}"
  end
end
