; extends

(fenced_code_block
  (info_string (language) @lang)
  (#eq? @lang "math")
  (code_fence_content) @image.content
  (#set! injection.language "latex")
  (#set! image.ext "tex")
) @image

(fenced_code_block
  (info_string (language) @lang)
  (#eq? @lang "mermaid")
  (code_fence_content) @image.content
  (#set! injection.language "mermaid")
  (#set! image.ext "mmd")
) @image

(fenced_code_block
  (info_string (language) @lang)
  (#eq? @lang "plotly")
  (code_fence_content) @image.content
  (#set! injection.language "json")
  (#set! image.ext "plotly")
) @image
