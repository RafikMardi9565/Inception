COMPOSE = docker compose -f srcs/docker-compose.yml
DATA    = /home/$(USER)/data


all: up

up:
	@mkdir -p $(DATA)/wordpress $(DATA)/mariadb
	$(COMPOSE) up -d --build

down:
	$(COMPOSE) down

clean:
	$(COMPOSE) down --rmi all

fclean: clean
	$(COMPOSE) down --volumes
	@mkdir -p $(DATA)
	docker run --rm -v $(DATA):/data debian:bookworm rm -rf /data/mariadb /data/wordpress

re: fclean all