NAME            =   cuda_store

# flags
OPMP            =   -fopenmp
SHA             =   -lcrypto
JSON            =   -ljansson

# 컴파일러
CC              =   gcc
NVCC            =   nvcc
RM              =   rm -rf

# 디렉터리
SRC_DIR         =   srcs/
INC_DIR         =   ./includes

# 소스 파일
C_SRCS          =   $(SRC_DIR)config.c $(SRC_DIR)main.c $(SRC_DIR)network.c $(SRC_DIR)timer.c
CU_SRCS         =   $(SRC_DIR)chunker.cu
C_OBJS          =   $(C_SRCS:.c=.o)
CU_OBJS         =   $(CU_SRCS:.cu=.o)

# 전체 대상
OBJS            =   $(C_OBJS) $(CU_OBJS)

# 규칙
all: $(NAME)

$(SRC_DIR)%.o: $(SRC_DIR)%.c
	$(CC) $(OPMP) -c $< -o $@ -I $(INC_DIR) $(SHA) $(JSON)

$(SRC_DIR)%.o: $(SRC_DIR)%.cu
	$(NVCC) -c $< -o $@ -I $(INC_DIR) -Xcompiler "$(OPMP)"

$(NAME): $(OBJS)
	$(NVCC) -o $@ $^ -Xcompiler "$(OPMP)" -I $(INC_DIR) $(SHA) $(JSON) -lcudart

clean:
	$(RM) $(C_OBJS) $(CU_OBJS)

fclean: clean
	$(RM) $(NAME)

re: fclean all

.PHONY: all clean fclean re
