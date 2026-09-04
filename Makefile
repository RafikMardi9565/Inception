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
	rm -rf $(DATA)

re: fclean all