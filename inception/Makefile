# ---------- VARIABLES ----------

COMPOSE = docker compose -f srcs/docker-compose.yml
DATA    = /home/$(USER)/data

# ---------- RULES ----------

all: up

up:
	@mkdir -p $(DATA)/wordpress $(DATA)/mariadb
	$(COMPOSE) up -d --build

down:
	$(COMPOSE) down

stop:
	$(COMPOSE) stop

start:
	$(COMPOSE) start

restart:
	$(COMPOSE) restart

logs:
	$(COMPOSE) logs -f

ps:
	$(COMPOSE) ps

clean:
	$(COMPOSE) down --rmi all

fclean: clean
	$(COMPOSE) down -v
	@mkdir -p $(DATA)
	docker run --rm -v $(DATA):/data debian:bookworm rm -rf /data/mariadb /data/wordpress

re: fclean all

.PHONY: all up down stop start restart logs ps clean fclean re
