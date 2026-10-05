<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>@DOMAIN@</title>
  <style>
    :root { color-scheme: light dark; }
    body {
      margin: 0;
      min-height: 100vh;
      display: grid;
      place-items: center;
      font-family: system-ui, -apple-system, "Segoe UI", Roboto, sans-serif;
      background: #f6f7f4;
      color: #22271f;
    }
    main { max-width: 34rem; padding: 2rem; text-align: center; }
    h1 { font-size: 1.6rem; margin: 0 0 .5rem; }
    p { line-height: 1.6; margin: .4rem 0; }
    code {
      background: #e6e9e0;
      border-radius: .25rem;
      padding: .15rem .4rem;
      font-size: .9em;
    }
    @media (prefers-color-scheme: dark) {
      body { background: #1b1f1a; color: #e8ece2; }
      code { background: #2c332b; }
    }
  </style>
</head>
<body>
  <main>
    <h1>@DOMAIN@ is live</h1>
    <p>This is the default page created by <strong>Bamboo-Site</strong>.</p>
    <p>Replace <code>public_html/index.html</code> inside the site's workspace with your own content.</p>
    <p>Nginx, SSL, Fail2ban and UFW are configured automatically.</p>
  </main>
</body>
</html>
