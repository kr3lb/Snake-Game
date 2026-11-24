# Projeto SNAKE — Assembly MIPS (MARS)

Implementação do jogo Snake em Assembly MIPS para o simulador MARS, conforme a
especificação: Bitmap Display com base `0x10010000`, área de 512 × 512 pixels,
célula de 8 × 8 pixels, comida de 1 célula, cobra crescendo ao comer, movimento
a cada 0,5 s e fim de jogo ao bater na parede ou no próprio corpo.

Arquivos:

| Arquivo | Conteúdo |
|---|---|
| `snake.asm` | Código-fonte único, todo comentado |
| `README.md` | Este documento (memória, registradores e roteiro de explicação) |

---

## 1. Como executar no MARS

1. **Tools → Bitmap Display** e configure exatamente:

   | Campo | Valor |
   |---|---|
   | Unit Width in Pixels | `8` |
   | Unit Height in Pixels | `8` |
   | Display Width in Pixels | `512` |
   | Display Height in Pixels | `512` |
   | Base address for display | `0x10010000 (static data)` |

   Clique em **Connect to MIPS**.

2. **Tools → Keyboard and Display MMIO Simulator → Connect to MIPS**
   (com o teclado conectado ao Bitmap Display).

3. Abra `snake.asm`, pressione **F3** (assemble) e **F5** (run).
   Clique na janela do simulador MMIO e use **W A S D**.

> Com unidade de 8 × 8 pixels, a tela de 512 × 512 tem 64 × 64 unidades.
> Cada célula do jogo é um bloco de **2 × 2 unidades = 16 × 16 pixels**, o que dá
> um tabuleiro de **32 × 32 células** (1024 células).

---

## 2. Como o jogo funciona (algoritmo)

```
tela base 0x10010000, tabuleiro 32x32 células (0 = vazio, 1 = corpo, 2 = comida)

main:
    limpa a tela
    init_game            -> zera tabuleiro, cria cobra (3 segmentos), sorteia
                            a semente pelo relogio do sistema e chama
                            spawn_food_near (1a comida perto da cabeca)
    render_all           -> desenho inicial
    loop:
        lê teclado (não bloqueante) e atualiza a direção pendente
        sleep(10 ms)  e conta 1 tick
        se ticks == 50 (0,5 s):
            step        -> anda 1 célula; se devolver 1, vai para game_over
```

`step` (o coração do jogo):

1. aplica a direção pendente do teclado;
2. calcula a nova célula: `nova_linha = linha + dr[dir]`, `nova_col = col + dc[dir]`;
3. se saiu do tabuleiro (`< 0` ou `>= 32`) → **game over** (parede);
4. se a nova célula tem corpo (`board = 1`): só é permitido se for a célula da
   cauda e a cobra **não** for crescer (a cauda sai no mesmo passo) — senão
   **game over**;
5. marca a nova célula, avança a cabeça no anel circular, redesenha (cabeça
   antiga vira corpo azul, nova cabeça branca) e apaga a cauda antiga;
6. se comeu: `score += 1`, a cauda **não** anda (cobra cresce) e uma nova comida
   é sorteada em uma célula vazia.

A comida nunca acaba: existe **uma** por vez na tela e, a cada vez que é comida,
`spawn_food` sorteia outra célula vazia — sem limite de repetições, até o game
over. A semente do gerador é o tempo do sistema (`syscall 30`), então cada
execução do jogo produz posições diferentes (a mesma partida nunca repete a
sequência da anterior). Para conferir onde a comida nasceu, cada respawn também
imprime `Nova comida em (linha,coluna)` no console do MARS.

Controle de direção: guarda-se **uma** direção pendente por passo (`pending_ok`).
Isso impede que duas teclas no mesmo intervalo façam a cobra "dar meia volta"
em cima do próprio corpo, e a direção oposta (180°) é sempre rejeitada.

---

## 3. Memória — o que foi usado e onde

### 3.1 Duas regiões de memória distintas

| Região | Endereço | Uso |
|---|---|---|
| Framebuffer (Bitmap Display) | `0x10010000` – `0x10013FFF` | 64 × 64 unidades × 4 bytes = 16 KB de pixels |
| Dados do programa (`.data`) | `0x10040000` em diante | tabuleiro, cobra, placar... |


### 3.2 Variáveis (base `0x10040000`)

| Rótulo | Offset | Tamanho | Significado |
|---|---|---|---|
| `board` | `+0x000` | 1024 bytes | estado de cada célula: 0 vazio, 1 corpo, 2 comida |
| `snake` | `+0x400` | 1024 **halfwords** | fila circular com o índice das células ocupadas |
| `head_i` | `+0xC00` | word | posição da **cabeça** dentro de `snake` |
| `tail_i` | `+0xC04` | word | posição da **cauda** dentro de `snake` |
| `length` | `+0xC08` | word | número de segmentos |
| `dir` | `+0xC0C` | word | direção atual: 0 cima, 1 direita, 2 baixo, 3 esquerda |
| `pending` / `pending_ok` | `+0xC10` | 2 words | direção pedida pelo teclado e flag "há pedido" |
| `food` | `+0xC18` | word | célula onde está a comida |
| `score` | `+0xC1C` | word | pontuação |
| `ticks` | `+0xC20` | word | contador de ticks (0 a 49) |
| `dr_table` / `dc_table` | `+0xC24` | 8 words | deslocamentos por direção (linha/coluna) |
| `rng_state` | `+0xC2C` | word | estado do gerador pseudo-aleatório da comida |

**Por que cada variável usa esse tipo?** Cada dado usa o menor tipo que o
representa sem perda:

* `board`: 3 valores possíveis (0/1/2) → **1 byte** por célula (1024 bytes);
* `snake`: a célula é `linha*32+coluna` (0 a 1023), que cabe em **16 bits** →
  `.half` de 2 bytes (2048 bytes). Com `.word` seriam 4096 bytes, o dobro,
  para guardar valores que nunca passam de 1023;
* `head_i`, `tail_i`, `length`, `dir`, `food`, `score`, `ticks`: **word**, que é
  o tipo natural de um contador e mantém o endereço alinhado (acesso `lw`/`sw`).

### 3.3 Representação da cobra: anel (fila circular) de 1024 posições

A célula é guardada como **um único número** `linha*32 + coluna` (0 a 1023), o
que cabe em 16 bits — daí o vetor ser de `.half` (2 bytes) — e dispensa matriz.

```
snake[] = [ ... | cauda | ... | corpo | cabeça | ... ]
                  ^tail_i                    ^head_i
```

* andar a cabeça: `head_i = (head_i + 1) AND 1023`
* andar a cauda : `tail_i = (tail_i + 1) AND 1023`
* o `AND 1023` é o `% 1024`: como 1024 é potência de 2, uma instrução `andi`
  resolve o "volta ao início", sem `div` (mais rápido e mais simples).
* crescer = **não** mover `tail_i` e somar 1 em `length`.

### 3.4 Endereçamento do Bitmap Display

Uma unidade de 8 × 8 pixels ocupa **1 word** (4 bytes) e a tela tem 64 unidades
por linha:

```
palavra = unidade_linha * 64 + unidade_coluna
byte    = 0x10010000 + 4 * palavra
```

O procedimento `draw_cell` recebe a célula `(r, c)`, converte para unidades
`(2r, 2c)` e escreve as 4 words do bloco:

```
end = 0x10010000 + 4 * ((2r) * 64 + 2c)
sw cor, 0(end)     # (2r,   2c)
sw cor, 4(end)     # (2r,   2c+1)
sw cor, 256(end)   # (2r+1, 2c)     -> 64*4 = 256 bytes para descer uma unidade
sw cor, 260(end)   # (2r+1, 2c+1)
```

`+4` = próxima unidade na horizontal; `+256` = próxima unidade na vertical.

### 3.5 Entrada/saída mapeada em memória (MMIO)

| Endereço | Leitura |
|---|---|
| `0xffff0000` | bit 0 = 1 quando há tecla disponível |
| `0xffff0004` | código ASCII da tecla (`w`=0x77, `a`=0x61, `s`=0x73, `d`=0x64) |

A leitura é **não bloqueante**: `read_key` testa o bit 0 e devolve 0 se nada foi
digitado, então o laço principal nunca "trava" esperando tecla. Depois de ler a
tecla, escreve 0 no registrador de controle para limpar o bit de *ready*.

### 3.6 Pilha (`$sp`, em `0x7fffeffc`)

Usada apenas para salvar `$ra` e os registradores `$s` que cada procedimento
usa. `step` salva 7 words (28 bytes) e `render_all`/`game_over` salvam 5.

---

## 4. Registradores — convenção e uso real no código

### 4.1 Convenção MIPS respeitada

| Grupo | Papel no projeto |
|---|---|
| `$zero` | constante 0 (ex.: `sb $zero` para apagar célula) |
| `$v0` | número da syscall / valor de retorno |
| `$a0`–`$a1` | argumentos: `$a0` = célula ou cor, `$a1` = cor |
| `$t0`–`$t9` | temporários, não sobrevivem a chamadas |
| `$s0`–`$s5` | variáveis que precisam sobreviver a `jal` → salvas na pilha |
| `$ra` | endereço de retorno, salvo em todo procedimento que chama outro |

### 4.2 Onde cada registrador foi usado

| Procedimento | Registradores | Para quê |
|---|---|---|
| `main` | `$t0` `$t1` | contador de ticks e limite `STEP_TICKS` |
| `read_key` | `$t0` `$t1` `$t2` | endereço do controle, teste do bit 0, endereço dos dados |
| `handle_key` | `$a0` `$t2` `$t3` `$t4` | tecla → direção; `$t4 = (dir+2) & 3` = direção oposta |
| `init_game` | `$t0`–`$t9` | zerar board, montar os 3 segmentos, gravar variáveis |
| `spawn_food` | `$t0` `$t1` `$t2` `$t3` | estado do LCG, constante do multiplicador, célula candidata, teste de ocupação e contador |
| `step` | `$s0` nova linha, `$s1` nova coluna, `$s2` nova célula, `$s3` comeu?, `$s4` cabeça antiga, `$s5` cauda antiga | estado do passo entre chamadas |
| `draw_cell` | `$a0` célula, `$a1` cor, `$t0`–`$t4` | divisão por 32, deslocamentos, endereço final |
| `fill_screen` | `$a0` cor, `$t0` ponteiro, `$t1` contador | pinta 4096 words |
| `render_all` | `$s0` índice no anel, `$s1` length, `$s2` contador, `$s3` último? | redesenhar cabeça de cor diferente |

### 4.3 Instruções que valem destaque

```asm
div  $s4, $t0        # separa linha e coluna de uma célula
mflo $t1             # linha  = célula / 32
mfhi $t2             # coluna = célula % 32
```
```asm
andi $t0, $t0, 1023  # (head_i + 1) % 1024 sem usar div
```
```asm
sll  $t1, $t1, 1     # 2*linha   (célula -> unidade)
sll  $t3, $t1, 6     # unidade_linha * 64
sll  $t3, $t3, 2     # * 4 bytes  -> deslocamento em bytes
```
```asm
jal draw_cell        # chamada de procedimento; $ra salvo na pilha
bnez $v0, game_over  # valor de retorno em $v0
```

---
