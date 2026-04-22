{
  perSystem = {
    pkgs,
    config,
    ...
  }: let
    # Version for the mdbook image
    version = "v1.0.0";

    # Simple Go static file server
    staticServer = pkgs.buildGo125Module {
      pname = "mdbook-server";
      version = "1.0.0";

      src = pkgs.runCommand "mdbook-server-src" {} ''
        mkdir -p $out
        cat > $out/main.go <<'EOF'
        package main

        import (
            "flag"
            "log"
            "net/http"
            "os"
            "path/filepath"
        )

        func main() {
            port := flag.String("port", "8080", "Port to listen on")
            dir := flag.String("dir", "/var/www/html", "Directory to serve")
            flag.Parse()

            // Resolve absolute path
            absDir, err := filepath.Abs(*dir)
            if err != nil {
                log.Fatal(err)
            }

            // Create file server with custom 404 handling
            fs := http.FileServer(http.Dir(absDir))
            http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
                // Check if file exists
                path := filepath.Join(absDir, filepath.Clean(r.URL.Path))
                if _, err := os.Stat(path); os.IsNotExist(err) {
                    // Try index.html for directory requests
                    indexPath := filepath.Join(path, "index.html")
                    if _, err := os.Stat(indexPath); err == nil {
                        http.ServeFile(w, r, indexPath)
                        return
                    }
                    // Serve custom 404 page if it exists
                    notFoundPath := filepath.Join(absDir, "404.html")
                    if _, err := os.Stat(notFoundPath); err == nil {
                        w.WriteHeader(http.StatusNotFound)
                        http.ServeFile(w, r, notFoundPath)
                        return
                    }
                }
                fs.ServeHTTP(w, r)
            })

            log.Printf("Starting server on port %s, serving files from %s", *port, absDir)
            if err := http.ListenAndServe(":"+*port, nil); err != nil {
                log.Fatal(err)
            }
        }
        EOF

        cat > $out/go.mod <<EOF
        module mdbook-server

        go 1.25
        EOF
      '';

      vendorHash = null;

      meta = {
        description = "Simple static file server for mdbook";
        mainProgram = "mdbook-server";
      };
    };

    # Build mdbook content (production)
    mdbookContent = environment: let
      bookConfig =
        if environment == "staging"
        then "book-staging.toml"
        else "book-prod.toml";
    in
      pkgs.stdenv.mkDerivation {
        pname = "mdbook-content-${environment}";
        version = "1.0.0";

        src = ../../..;

        nativeBuildInputs = with pkgs; [
          mdbook
          mdbook-kroki-preprocessor
        ];

        buildPhase = ''
          cd mdbook
          ln -sf ${bookConfig} book.toml

          # Update commit marker
          COMMIT=${config.flake.rev or "dirty-${config.flake.dirtyRev or "unknown"}"}
          sed -i "s|italic\">.*</span>|italic\">$COMMIT</span>|g" README-book.md

          mdbook build
        '';

        installPhase = ''
          mkdir -p $out
          cp -r ../static/book${
            if environment == "staging"
            then "-staging"
            else ""
          }.play.dev.cardano.org/* $out/

          # Add robots.txt for staging to prevent indexing
          ${
            if environment == "staging"
            then ''
                  cat > $out/robots.txt <<EOF
              User-agent: *
              Disallow: /
              EOF
            ''
            else ""
          }

          # Add noindex meta tag to staging HTML files
          ${
            if environment == "staging"
            then ''
              find $out -name "*.html" -type f -exec sed -i 's|<head>|<head>\n    <meta name="robots" content="noindex, nofollow">|' {} \;
            ''
            else ""
          }
        '';
      };

    # Create Docker image for mdbook
    mkMdbookImage = environment:
      pkgs.dockerTools.buildLayeredImage {
        name = "mdbook-${environment}";
        tag = version;

        contents = [
          pkgs.cacert
          staticServer
        ];

        extraCommands = ''
          mkdir -p var/www/html tmp etc

          # Create passwd/group inline instead of fakeNss (avoids symlink escape issue)
          echo "root:x:0:0:root:/root:/bin/sh" > etc/passwd
          echo "nobody:x:65534:65534:nobody:/nonexistent:/bin/sh" >> etc/passwd
          echo "root:x:0:" > etc/group
          echo "nobody:x:65534:" >> etc/group

          cp -r ${mdbookContent environment}/* var/www/html/

          # Ensure nobody user has access
          chmod -R 755 var/www/html
          chmod 1777 tmp
        '';

        config = {
          Cmd = ["${staticServer}/bin/mdbook-server" "-port" "8080" "-dir" "/var/www/html"];
          ExposedPorts = {
            "8080/tcp" = {};
          };
          User = "nobody";
          WorkingDir = "/var/www/html";
        };
      };
  in {
    packages = {
      mdbook-production-image = mkMdbookImage "production";
      mdbook-staging-image = mkMdbookImage "staging";
    };
  };
}
