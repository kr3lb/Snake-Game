# ============================================================================
#  PROJETO SNAKE  -  Implementacao em Assembly MIPS (simulador MARS)
#  Arquivo: snake.asm
# ============================================================================
# ---------------------------- constantes ------------------------------------
.eqv GRID        32            # 32 x 32 celulas (cada celula = 16x16 px)
.eqv CELLS       1024          # GRID*GRID
.eqv DISPLAY     0x10010000    # endereco base do Bitmap Display
.eqv KEY_CTRL    0xffff0000    # bit 0 = tecla disponivel
.eqv KEY_DATA    0xffff0004    # codigo ASCII da tecla

.eqv BG_COLOR    0x00101418    # fundo (cinza bem escuro)
.eqv HEAD_COLOR  0x00FFFFFF    # cabeca (branco)
.eqv BODY_COLOR  0x0029B6F6    # corpo  (azul)
.eqv FOOD_COLOR  0x0034D058    # comida (verde)
.eqv OVER_COLOR  0x00A51D1D    # tela de game over (vermelho escuro)

.eqv TICK_MS     10            # duracao de 1 tick em milissegundos
.eqv STEP_TICKS  50            # 50 ticks = 500 ms = 0.5 s por movimento
.eqv SCORE_STEP  1             # pontos por comida (pode ser 5)

# ============================ segmento de dados =============================
# IMPORTANTE: o framebuffer do Bitmap Display comeca em 0x10010000 (endereco
# pedido na especificacao) e ocupa 64*64 = 4096 words = 16 KB, ou seja, vai de
# 0x10010000 ate 0x10013FFF. Como esse endereco coincide com o inicio padrao do
# segmento .data do MARS, os dados do programa sao colocados em 0x10040000
# (regiao que o MARS reserva para o heap e que este programa nao usa). Assim o
# desenho da tela nunca sobrescreve as variaveis do jogo.
.data 0x10040000
.align 2

board:       .space 1024       # 32*32 bytes
snake:       .space 2048       # 1024 halfwords de 2 bytes = anel de celulas
head_i:      .word 0
tail_i:      .word 0
length:      .word 0
dir:         .word 1           # comeca indo para a direita
pending:     .word 1
pending_ok:  .word 0
food:        .word 0
score:       .word 0
ticks:       .word 0

# tabelas de deslocamento: indice = direcao (0=cima 1=dir 2=baixo 3=esq)
dr_table:    .word -1, 0, 1, 0
dc_table:    .word  0, 1, 0, -1

# estado do gerador pseudo-aleatorio proprio usado por spawn_food.
# A semente e trocada em init_game pelo tempo do sistema (syscall 30), por
# isso as posicoes sorteadas mudam a cada partida.
rng_state:   .word 24601

msg_start:   .asciiz "SNAKE MIPS - use W (cima), A (esquerda), S (baixo), D (direita)\n"
msg_score:   .asciiz "Comida! Pontuacao: "
msg_over:    .asciiz "\nGAME OVER - Pontuacao final: "
msg_food_at: .asciiz "Nova comida em "
msg_first_food: .asciiz "Primeira comida em "

# ============================ segmento de texto =============================
.text
.globl main

# ----------------------------------------------------------------------------
# main: inicializa o jogo e executa o laco principal.
#   O laco faz tres coisas: le o teclado, dorme TICK_MS e, quando completou
#   STEP_TICKS ticks, executa um passo da cobra.
# ----------------------------------------------------------------------------
main:
    li        $v0, 4               # imprime as instrucoes no console
    la        $a0, msg_start
    syscall

    jal       clear_screen         # pinta a area do jogo com a cor de fundo
    jal       init_game            # zera tabuleiro, cria cobra e comida
    jal       render_all           # desenha o estado inicial

main_loop:
    jal       read_key             # v0 = tecla lida (0 se nenhuma)
    move      $a0, $v0
    jal       handle_key           # atualiza a direcao pedida

    li        $v0, 32              # sleep(TICK_MS)
    li        $a0, TICK_MS
    syscall

    lw        $t0, ticks
    addi      $t0, $t0, 1
    li        $t1, STEP_TICKS
    blt       $t0, $t1, main_save_tick     # ainda nao deu 0.5 s

    sw        $zero, ticks         # zerou o contador: hora de andar
    jal       step                 # v0 = 1 se o jogo acabou
    bnez      $v0, game_over
    j         main_loop

main_save_tick:
    sw        $t0, ticks
    j         main_loop

# ----------------------------------------------------------------------------
# read_key: leitura NAO bloqueante do teclado MMIO.
#   Entrada: nenhuma.  Saida: $v0 = codigo ASCII ou 0 se nada foi digitado.
#   Usa $t0 = endereco do registrador de controle, $t1 = conteudo do
#   controle (bit 0 = ready), $t2 = endereco do registrador de dados.
# ----------------------------------------------------------------------------
read_key:
    li        $t0, KEY_CTRL
    lw        $t1, 0($t0)
    andi      $t1, $t1, 1          # testa apenas o bit "ready"
    beqz      $t1, rk_none
    li        $t2, KEY_DATA
    lw        $v0, 0($t2)          # tecla disponivel
    sw        $zero, 0($t0)        # limpa o bit de ready
    jr        $ra
rk_none:
    li        $v0, 0
    jr        $ra

# ----------------------------------------------------------------------------
# handle_key: converte a tecla em direcao e guarda como direcao pendente.
#   Entrada: $a0 = codigo ASCII (0 = nada).
#   Regra: so aceita um pedido por passo (pending_ok) e rejeita a direcao
#   oposta a atual, para a cobra nunca "dar meia volta" sobre o proprio corpo.
# ----------------------------------------------------------------------------
handle_key:
    beqz      $a0, hk_done
    li        $t0, 0x77            # 'w'
    beq       $a0, $t0, hk_up
    li        $t0, 0x57            # 'W'
    beq       $a0, $t0, hk_up
    li        $t0, 0x64            # 'd'
    beq       $a0, $t0, hk_right
    li        $t0, 0x44            # 'D'
    beq       $a0, $t0, hk_right
    li        $t0, 0x73            # 's'
    beq       $a0, $t0, hk_down
    li        $t0, 0x53            # 'S'
    beq       $a0, $t0, hk_down
    li        $t0, 0x61            # 'a'
    beq       $a0, $t0, hk_left
    li        $t0, 0x41            # 'A'
    beq       $a0, $t0, hk_left
    j         hk_done              # outra tecla: ignora

hk_up:    li $t2, 0
          j  hk_try
hk_right: li $t2, 1
          j  hk_try
hk_down:  li $t2, 2
          j  hk_try
hk_left:  li $t2, 3

hk_try:
    lw        $t3, pending_ok
    bnez      $t3, hk_done         # ja existe um pedido para este passo
    lw        $t3, dir             # direcao atual
    addi      $t4, $t3, 2
    andi      $t4, $t4, 3          # (dir + 2) % 4 = direcao oposta
    beq       $t2, $t4, hk_done    # 180 graus: proibido
    beq       $t2, $t3, hk_done    # mesma direcao: nada a fazer
    sw        $t2, pending
    li        $t3, 1
    sw        $t3, pending_ok
hk_done:
    jr        $ra

# ----------------------------------------------------------------------------
# init_game: prepara tabuleiro, cobra (3 segmentos no centro) e variaveis.
#   A cobra nasce na linha 16, colunas 14,15,16; o ultimo indice do anel
#   (head_i = 2) e a cabeca, indo para a direita.
# ----------------------------------------------------------------------------
init_game:
    addi      $sp, $sp, -4         # init_game chama spawn_food, entao
    sw        $ra, 0($sp)          # $ra precisa ser preservado na pilha

    la        $t0, board           # zera 1024 bytes = 256 words
    li        $t1, 256
    li        $t2, 0
ig_zero:
    sw        $t2, 0($t0)
    addi      $t0, $t0, 4
    addi      $t1, $t1, -1
    bgtz      $t1, ig_zero

    li        $t0, 16              # linha do centro
    li        $t1, 14              # coluna inicial (cauda)
    li        $t2, 3               # comprimento inicial
    la        $t3, snake
    li        $t4, 0               # i = 0
ig_snake:
    add       $t5, $t1, $t4        # coluna do segmento i
    li        $t6, GRID
    mul       $t7, $t0, $t6        # linha * 32
    add       $t7, $t7, $t5        # + coluna = indice da celula
    sll       $t8, $t4, 1          # i * 2 (halfword)
    add       $t8, $t8, $t3
    sh        $t7, 0($t8)          # snake[i] = celula
    la        $t9, board
    add       $t9, $t9, $t7
    li        $t8, 1
    sb        $t8, 0($t9)          # board[celula] = 1 (corpo)
    addi      $t4, $t4, 1
    blt       $t4, $t2, ig_snake

    li        $t0, 2
    sw        $t0, head_i          # cabeca = ultimo inserido
    sw        $zero, tail_i        # cauda = primeiro inserido
    sw        $t2, length
    li        $t0, 1
    sw        $t0, dir             # andando para a direita
    sw        $t0, pending
    sw        $zero, pending_ok
    sw        $zero, score
    sw        $zero, ticks

    # ---- semente do sorteio ----------------
    # syscall 30 devolve o tempo do sistema em milissegundos ($a0 = parte
    # baixa, $a1 = parte alta). Misturar os dois bits e forcar o bit 0 em 1
    # evita a semente 0 (o LCG ficaria preso em 12345 para sempre).
    li        $v0, 30
    syscall
    xor       $t0, $a0, $a1
    ori       $t0, $t0, 1
    sw        $t0, rng_state

    # primeira comida: sorteada perto da cabeca, para aparecer na tela logo
    # no inicio (as seguintes sao sorteadas em qualquer celula vazia)
    jal       spawn_food_near
    li        $v0, 4
    la        $a0, msg_first_food
    syscall
    jal       print_food_pos
    li        $v0, 11
    li        $a0, 10
    syscall

    lw        $ra, 0($sp)          # devolve o endereco de retorno de main
    addi      $sp, $sp, 4
    jr        $ra

# ----------------------------------------------------------------------------
# spawn_food: sorteia uma celula vazia e coloca a comida nela.
#   O sorteio e feito por um gerador pseudo-aleatorio proprio (LCG):
#       estado = estado * 1103515245 + 12345   (mantendo os 32 bits baixos)
#   e a celula candidata e (estado >> 16) AND 1023, sempre em [0,1023].
#   Nao depende da syscall 42, entao o comportamento e identico em qualquer
#   versao do MARS. Se a celula sorteada ja estiver ocupada, o codigo avanca
#   (celula+1, +2, ... com volta para o inicio) ate achar uma vazia; assim a
#   comida SEMPRE aparece enquanto houver celula livre e nunca e desenhada
#   fora do tabuleiro.
#   Saida: $v0 = 1 se colocou, 0 se o tabuleiro esta cheio (vitoria).
# ----------------------------------------------------------------------------
spawn_food:
    addi      $sp, $sp, -4
    sw        $ra, 0($sp)
    jal       rand_cell            # v0 = celula candidata em [0,1023]
    move      $t0, $v0

    li        $t2, 0               # tentativas ja feitas
sf_try:
    la        $t1, board
    add       $t1, $t1, $t0
    lb        $t3, 0($t1)
    beqz      $t3, sf_ok           # celula vazia: pode usar
    addi      $t0, $t0, 1
    andi      $t0, $t0, 1023       # proxima celula (circular)
    addi      $t2, $t2, 1
    li        $t3, CELLS
    blt       $t2, $t3, sf_try
    li        $v0, 0               # tabuleiro cheio: vitoria
    lw        $ra, 0($sp)
    addi      $sp, $sp, 4
    jr        $ra
sf_ok:
    li        $t3, 2
    sb        $t3, 0($t1)          # board[celula] = 2 (comida)
    sw        $t0, food
    li        $v0, 1
    lw        $ra, 0($sp)
    addi      $sp, $sp, 4
    jr        $ra

# ----------------------------------------------------------------------------
# rand_cell: avanca o LCG e devolve em $v0 uma celula candidata em [0,1023].
#   Fica em uma rotina so para nao duplicar o codigo do sorteio.
# ----------------------------------------------------------------------------
rand_cell:
    lw        $t0, rng_state
    li        $t1, 1103515245      # multiplicador do LCG
    mul       $t0, $t0, $t1        # estado * multiplicador
    addiu     $t0, $t0, 12345      # + incremento
    sw        $t0, rng_state
    srl       $t0, $t0, 16         # bits altos sao mais "aleatorios"
    andi      $v0, $t0, 1023       # celula candidata em [0,1023]
    jr        $ra

# ----------------------------------------------------------------------------
# spawn_food_near: sorteia a PRIMEIRA comida em uma celula vazia a no maximo
#   8 celulas (distancia Manhattan) da cabeca, isto e, perto dela, visivel na
#   tela desde o inicio do jogo. Faz ate 64 tentativas; se nenhuma servir
#   (tabuleiro muito cheio), cai no spawn_food normal.
#   Saida: $v0 = 1 se colocou, 0 se nao havia celula livre.
# ----------------------------------------------------------------------------
spawn_food_near:
    addi      $sp, $sp, -16
    sw        $ra, 12($sp)
    sw        $s0, 8($sp)
    sw        $s1, 4($sp)
    sw        $s3, 0($sp)

    jal       get_head_cell        # posicao da cabeca
    li        $t0, GRID
    div       $v0, $t0
    mflo      $s0                  # linha da cabeca
    mfhi      $s1                  # coluna da cabeca
    li        $s3, 64              # tentativas
sn_try:
    jal       rand_cell
    move      $t0, $v0
    la        $t1, board
    add       $t1, $t1, $t0
    lb        $t2, 0($t1)
    bnez      $t2, sn_next         # ocupada
    li        $t2, GRID
    div       $t0, $t2
    mflo      $t3                  # linha candidata
    mfhi      $t4                  # coluna candidata
    sub       $t3, $t3, $s0
    abs       $t3, $t3
    sub       $t4, $t4, $s1
    abs       $t4, $t4
    add       $t3, $t3, $t4        # distancia Manhattan ate a cabeca
    beqz      $t3, sn_next         # nao na propria cabeca
    li        $t4, 9
    bge       $t3, $t4, sn_next    # longe demais: sorteia outra
    li        $t2, 2
    sb        $t2, 0($t1)          # board[celula] = 2 (comida)
    sw        $t0, food
    li        $v0, 1
    j         sn_ret
sn_next:
    addi      $s3, $s3, -1
    bgtz      $s3, sn_try
    jal       spawn_food           # fallback: qualquer celula vazia
sn_ret:
    lw        $ra, 12($sp)
    lw        $s0, 8($sp)
    lw        $s1, 4($sp)
    lw        $s3, 0($sp)
    addi      $sp, $sp, 16
    jr        $ra

# ----------------------------------------------------------------------------
# print_food_pos: imprime "(linha,coluna)" da comida atual no console.
#   Usado no inicio e a cada nova comida, para conferir com o desenho na tela.
# ----------------------------------------------------------------------------
print_food_pos:
    li        $v0, 11
    li        $a0, 40              # '('
    syscall
    lw        $t0, food
    li        $t1, GRID
    div       $t0, $t1
    mflo      $t0                  # linha
    mfhi      $t1                  # coluna
    li        $v0, 1
    move      $a0, $t0
    syscall                        # linha
    li        $v0, 11
    li        $a0, 44              # ','
    syscall
    li        $v0, 1
    move      $a0, $t1
    syscall                        # coluna
    li        $v0, 11
    li        $a0, 41              # ')'
    syscall
    jr        $ra

# ----------------------------------------------------------------------------
# get_head_cell: retorna a celula (linha*32+coluna) da cabeca em $v0.
#   Lembrando o anel: snake[head_i].
# ----------------------------------------------------------------------------
get_head_cell:
    lw        $t0, head_i
    la        $t1, snake
    sll       $t2, $t0, 1          # indice * 2 bytes (halfword)
    add       $t1, $t1, $t2
    lh        $v0, 0($t1)
    jr        $ra

# ----------------------------------------------------------------------------
# step: executa UM movimento da cobra.
#   1. aplica a direcao pendente;
#   2. calcula a nova celula a partir da cabeca + tabela de deslocamento;
#   3. testa parede e corpo (a celula da cauda e liberada no mesmo passo);
#   4. insere a nova cabeca no anel, apaga a cauda antiga (se nao cresceu);
#   5. redesenha somente as celulas que mudaram;
#   6. se comeu: soma pontos, alonga e sorteia nova comida.
#   Saida: $v0 = 0 (jogo continua) / 1 (fim de jogo).
#   Guarda $s0 = nova linha, $s1 = nova coluna, $s2 = nova celula,
#          $s3 = 1 se comeu, $s4 = celula da cabeca antiga, $s5 = cauda antiga.
# ----------------------------------------------------------------------------
step:
    addi      $sp, $sp, -28
    sw        $ra, 24($sp)
    sw        $s0, 20($sp)
    sw        $s1, 16($sp)
    sw        $s2, 12($sp)
    sw        $s3, 8($sp)
    sw        $s4, 4($sp)
    sw        $s5, 0($sp)

    # ---- 1) direcao pendente ----
    lw        $t0, pending_ok
    beqz      $t0, st_dir_ok
    lw        $t0, pending
    sw        $t0, dir
    sw        $zero, pending_ok
st_dir_ok:

    # ---- 2) nova celula = cabeca + deslocamento ----
    jal       get_head_cell
    move      $s4, $v0             # celula atual da cabeca
    li        $t0, GRID
    div       $s4, $t0
    mflo      $t1                  # linha  (s4 / 32)
    mfhi      $t2                  # coluna (s4 % 32)
    lw        $t3, dir
    sll       $t4, $t3, 2          # deslocamento no vetor de tabelas
    la        $t5, dr_table
    add       $t5, $t5, $t4
    lw        $t6, 0($t5)
    add       $s0, $t1, $t6        # nova linha
    la        $t5, dc_table
    add       $t5, $t5, $t4
    lw        $t6, 0($t5)
    add       $s1, $t2, $t6        # nova coluna

    # ---- 3a) colisao com as paredes ----
    bltz      $s0, st_over
    bltz      $s1, st_over
    li        $t0, GRID
    bge       $s0, $t0, st_over
    bge       $s1, $t0, st_over

    mul       $s2, $s0, $t0
    add       $s2, $s2, $s1        # indice da nova celula

    # ---- 3b) comendo? ----
    li        $s3, 0
    lw        $t1, food
    bne       $s2, $t1, st_body
    li        $s3, 1               # s3 = 1 -> vai crescer

st_body:
    la        $t0, board
    add       $t0, $t0, $s2
    lb        $t1, 0($t0)
    li        $t2, 1
    bne       $t1, $t2, st_move    # celula livre ou comida: ok
    bnez      $s3, st_over         # corpo + crescer = colisao real
    lw        $t1, tail_i
    la        $t2, snake
    sll       $t3, $t1, 1          # * 2 bytes
    add       $t2, $t2, $t3
    lh        $t2, 0($t2)          # celula da cauda
    bne       $s2, $t2, st_over    # corpo e nao e a cauda: colisao

st_move:
    la        $t0, board
    add       $t0, $t0, $s2
    li        $t1, 1
    sb        $t1, 0($t0)          # marca a nova cabeca no tabuleiro

    lw        $t0, head_i          # avanca a cabeca no anel
    addi      $t0, $t0, 1
    andi      $t0, $t0, 1023       # (head_i + 1) % 1024
    sw        $t0, head_i
    la        $t1, snake
    sll       $t2, $t0, 1          # * 2 bytes
    add       $t1, $t1, $t2
    sh        $s2, 0($t1)          # snake[head_i] = nova celula

    move      $a0, $s4             # cabeca antiga agora e corpo
    li        $a1, BODY_COLOR
    jal       draw_cell
    move      $a0, $s2             # desenha a nova cabeca
    li        $a1, HEAD_COLOR
    jal       draw_cell

    bnez      $s3, st_grow

    # ---- 4) sem crescimento: apaga a cauda antiga ----
    lw        $t0, tail_i
    la        $t1, snake
    sll       $t2, $t0, 1          # * 2 bytes
    add       $t1, $t1, $t2
    lh        $s5, 0($t1)          # celula da cauda antiga
    la        $t0, board
    add       $t0, $t0, $s5
    sb        $zero, 0($t0)        # libera a celula
    move      $a0, $s5
    li        $a1, BG_COLOR
    jal       draw_cell
    lw        $t0, tail_i          # avanca a cauda no anel
    addi      $t0, $t0, 1
    andi      $t0, $t0, 1023
    sw        $t0, tail_i
    j         st_ok

st_grow:
    # ---- 5) comeu: pontuacao + crescimento + nova comida ----
    lw        $t0, score
    addi      $t0, $t0, SCORE_STEP
    sw        $t0, score
    li        $v0, 4
    la        $a0, msg_score
    syscall
    li        $v0, 1
    lw        $a0, score
    syscall
    li        $v0, 11
    li        $a0, 10
    syscall

    lw        $t0, length          # a cauda nao anda: a cobra cresce
    addi      $t0, $t0, 1
    sw        $t0, length

    jal       spawn_food
    beqz      $v0, st_over         # tabuleiro cheio = vitoria
    lw        $a0, food
    li        $a1, FOOD_COLOR
    jal       draw_cell

    # ---- confirma no console onde a nova comida nasceu ----
    # (serve de teste: se esta linha aparece, a comida foi sorteada e
    #  desenhada; a posicao impressa e a mesma celula pintada de verde)
    li        $v0, 4
    la        $a0, msg_food_at
    syscall
    jal       print_food_pos
    li        $v0, 11
    li        $a0, 10
    syscall

st_ok:
    li        $v0, 0
    j         st_ret
st_over:
    li        $v0, 1
st_ret:
    lw        $ra, 24($sp)
    lw        $s0, 20($sp)
    lw        $s1, 16($sp)
    lw        $s2, 12($sp)
    lw        $s3, 8($sp)
    lw        $s4, 4($sp)
    lw        $s5, 0($sp)
    addi      $sp, $sp, 28
    jr        $ra

# ----------------------------------------------------------------------------
# render_all: redesenha a tela inteira (usado na inicializacao e no fim).
# ----------------------------------------------------------------------------
render_all:
    addi      $sp, $sp, -20
    sw        $ra, 16($sp)
    sw        $s0, 12($sp)
    sw        $s1, 8($sp)
    sw        $s2, 4($sp)
    sw        $s3, 0($sp)

    jal       clear_screen
    lw        $a0, food            # comida
    li        $a1, FOOD_COLOR
    jal       draw_cell

    lw        $s0, tail_i          # indice no anel (comeca na cauda)
    lw        $s1, length
    li        $s2, 0               # i
ra_loop:
    bge       $s2, $s1, ra_done
    la        $t1, snake
    sll       $t2, $s0, 1          # * 2 bytes
    add       $t1, $t1, $t2
    lh        $a0, 0($t1)
    li        $a1, BODY_COLOR
    addi      $s3, $s1, -1
    bne       $s2, $s3, ra_draw    # o ultimo segmento e a cabeca
    li        $a1, HEAD_COLOR
ra_draw:
    jal       draw_cell
    addi      $s0, $s0, 1
    andi      $s0, $s0, 1023       # anda no anel circular
    addi      $s2, $s2, 1
    j         ra_loop
ra_done:
    lw        $ra, 16($sp)
    lw        $s0, 12($sp)
    lw        $s1, 8($sp)
    lw        $s2, 4($sp)
    lw        $s3, 0($sp)
    addi      $sp, $sp, 20
    jr        $ra

# ----------------------------------------------------------------------------
# draw_cell: pinta UMA celula do jogo (2x2 unidades = 16x16 pixels).
#   Entrada: $a0 = celula (linha*32 + coluna), $a1 = cor 0x00RRGGBB.
#
#   Endereco de memoria do Bitmap Display (unidade 8x8, tela 64x64 unidades):
#       palavra = (unidade_linha * 64) + unidade_coluna
#       byte    = 0x10010000 + 4 * palavra
#   A celula (r,c) ocupa as unidades (2r, 2c), (2r, 2c+1), (2r+1, 2c) e
#   (2r+1, 2c+1): 4 palavras, nos deslocamentos +0, +4, +256 e +260.
# ----------------------------------------------------------------------------
draw_cell:
    li        $t0, GRID
    div       $a0, $t0
    mflo      $t1                  # linha da celula
    mfhi      $t2                  # coluna da celula
    sll       $t1, $t1, 1          # unidade_linha = 2 * linha
    sll       $t2, $t2, 1          # unidade_coluna = 2 * coluna
    sll       $t3, $t1, 6          # unidade_linha * 64
    add       $t3, $t3, $t2
    sll       $t3, $t3, 2          # * 4 bytes
    li        $t4, DISPLAY
    add       $t3, $t3, $t4        # endereco da unidade superior esquerda
    sw        $a1, 0($t3)
    sw        $a1, 4($t3)
    sw        $a1, 256($t3)
    sw        $a1, 260($t3)
    jr        $ra

# ----------------------------------------------------------------------------
# fill_screen: pinta os 4096 words (64x64 unidades) com a cor em $a0.
# ----------------------------------------------------------------------------
fill_screen:
    li        $t0, DISPLAY
    li        $t1, 4096
fs_loop:
    sw        $a0, 0($t0)
    addi      $t0, $t0, 4
    addi      $t1, $t1, -1
    bnez      $t1, fs_loop
    jr        $ra

# ----------------------------------------------------------------------------
# clear_screen: pinta a tela toda com a cor de fundo.
# ----------------------------------------------------------------------------
clear_screen:
    li        $a0, BG_COLOR
    j         fill_screen

# ----------------------------------------------------------------------------
# game_over: mostra a pontuacao, pisca a tela em vermelho, redesenha o
#            tabuleiro final e encerra o programa.
# ----------------------------------------------------------------------------
game_over:
    addi      $sp, $sp, -8
    sw        $ra, 4($sp)
    sw        $s0, 0($sp)

    li        $v0, 4
    la        $a0, msg_over
    syscall
    li        $v0, 1
    lw        $a0, score
    syscall
    li        $v0, 11
    li        $a0, 10
    syscall

    li        $s0, 3
go_blink:
    li        $a0, OVER_COLOR
    jal       fill_screen
    li        $v0, 32
    li        $a0, 200
    syscall
    jal       clear_screen
    li        $v0, 32
    li        $a0, 200
    syscall
    addi      $s0, $s0, -1
    bgtz      $s0, go_blink

    jal       render_all           # deixa o estado final na tela
    li        $v0, 10              # exit
    syscall
