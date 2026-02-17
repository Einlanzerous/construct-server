.PHONY: network up down db-up db-shell db-check

# Create the construct_net Docker bridge network (required before starting the stack)
network:
	docker network create construct_net 2>/dev/null || echo "construct_net already exists"

# Start the full stack
up: network
	docker compose up -d

# Stop the full stack
down:
	docker compose down

# Start only the postgres service
db-up: network
	docker compose up -d postgres

# Open a psql shell to the running postgres container
db-shell:
	docker compose exec postgres psql -U postgres

# Verify databases and users were created correctly
db-check:
	@echo "=== Databases ==="
	@docker compose exec postgres psql -U postgres -c "\l" | grep -E "vox_loop|cook_book"
	@echo ""
	@echo "=== User access: vox_loop ==="
	@docker compose exec postgres psql -U vox_loop_user -d vox_loop -c "SELECT 1 AS connected;"
	@echo "=== User access: cook_book ==="
	@docker compose exec postgres psql -U cook_book_user -d cook_book -c "SELECT 1 AS connected;"
