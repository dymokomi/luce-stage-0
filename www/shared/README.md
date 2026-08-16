# Shared public-site styling

`core.css` is the single source for the palette, typography, common header
controls, prose, code samples, tables, navigation cards, and previous/next
links used across the LuciaOS sites.

Every site copies this file into its own output and serves it from its own
origin. Site stylesheets load after it and contain only that site's frame and
layout. Never edit a copied `core.css`; edit this one and rebuild the site.
