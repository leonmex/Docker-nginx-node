### Command for the Shop
docker compose restart shop && sleep 3 && curl -sk https://localhost:3002/en/ | grep -o '<title>[^<]*'

sleep 6 && curl -sk https://localhost:3002/en/ | grep -o '<title>[^<]*'; echo "---"; curl -sk https://localhost:3002/en/?config=home-with-filters | grep -o 'panelTitle\|Filters\|Filtros\|Filter<' | head -5

curl -sk --max-time 10 "https://localhost:3002/en?config=home-with-filters" -o /tmp/claude-1000/-home-ander-projects-Docker-nginx-node/ca26bccb-4833-476d-8809-9137f932cf3a/scratchpad/page.html -w "HTTP %{http_code}, size %{size_download}\n"
grep -o "Filters\|Categories\|Colors\|Brands\|Apply Filters\|Clear All\|Price Range" /tmp/claude-1000/-home-ander-projects-Docker-nginx-node/ca26bccb-4833-476d-8809-9137f932cf3a/scratchpad/page.html | sort | uniq -c

curl -sk --max-time 10 "https://localhost:3002/de?config=home-with-filters" -o /tmp/claude-1000/-home-ander-projects-Docker-nginx-node/ca26bccb-4833-476d-8809-9137f932cf3a/scratchpad/page-de.html -w "HTTP %{http_code}\n"
grep -o "Filter anwenden\|Kategorien\|Farben\|Marken\|Alle löschen\|Preisspanne\|>Filter<" /tmp/claude-1000/-home-ander-projects-Docker-nginx-node/ca26bccb-4833-476d-8809-9137f932cf3a/scratchpad/page-de.html | sort | uniq -c

curl -sk --max-time 10 "https://localhost:3002/es?config=home-with-filters" -o /tmp/claude-1000/-home-ander-projects-Docker-nginx-node/ca26bccb-4833-476d-8809-9137f932cf3a/scratchpad/page-es.html -w "HTTP %{http_code}\n"
grep -o "Aplicar Filtros\|Categorías\|Colores\|Marcas\|Borrar Todo\|Rango de Precio" /tmp/claude-1000/-home-ander-projects-Docker-nginx-node/ca26bccb-4833-476d-8809-9137f932cf3a/scratchpad/page-es.html | sort | uniq -c


cd /home/ander/projects/Docker-nginx-node
git restore --staged \
  "infra/terraform/bootstrap/.terraform" \
  "infra/terraform/bootstrap/bootstrap.tfplan" \
  "infra/terraform/bootstrap/terraform.tfstate" \
  "infra/terraform/bootstrap/terraform.tfstate.backup" \
  "infra/terraform/environments/prod/.terraform" \
  "infra/terraform/environments/prod/prod.tfplan"
echo "=== staged now ==="
git status --short infra/