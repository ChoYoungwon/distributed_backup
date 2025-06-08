NAME			=	parrel_store

# flags
OPMP = -fopenmp
SHA = -lcrypto
JSON = -ljansson

# command
CC				=	gcc
RM				=	rm -rf

# directory
SRC_DIR			=	srcs/
INC_DIR			=	./includes

# srcs
SRCS			=	$(SRC_DIR)chunker.c $(SRC_DIR)config.c $(SRC_DIR)main.c $(SRC_DIR)network.c $(SRC_DIR)timer.c
OBJS			=	$(SRCS:.cpp=.o)

all:	$(NAME)

.cpp.o: 
	$(CC) $(OPMP) -c $< -o $@ -I $(INC_DIR) $(SHA) $(JSON)

$(NAME): $(OBJS)
	$(CC) $(OPMP) -o $(NAME) $(OBJS) -I $(INC_DIR) $(SHA) $(JSON)

clean:
	rm -f $(OBJS) ./srcs/$(NAME)

fclean: clean
	$(RM) $(NAME)

re:	fclean all

.PHONY: all clean fclean re