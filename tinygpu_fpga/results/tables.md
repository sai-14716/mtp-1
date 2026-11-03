| Cores | Prog ports | Data ports | Dispatcher | Clock (MHz) | LUT | LUT % | FF | BRAM | DSP | WNS (ns) | Timing met | Fmax est. (MHz) | Critical path |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 1 | 1 | 4 | stock | 50 | 1,877 | 2.96 | 1,520 | 3.5 | 0 | 1.089 | yes | 52.9 | ALU divider |
| 2 | 1 | 4 | stock | 50 | 3,259 | 5.14 | 2,489 | 3.5 | 0 | 1.394 | yes | 53.7 | ALU divider |
| 4 | 1 | 4 | stock | 50 | 6,253 | 9.86 | 4,400 | 3.5 | 0 | 1.535 | yes | 54.2 | ALU divider |
| 8 | 1 | 4 | stock | 50 | 12,904 | 20.35 | 8,226 | 3.5 | 0 | 0.127 | yes | 50.3 | dispatcher |
| 16 | 1 | 4 | stock | 50 | 29,416 | 46.4 | 15,883 | 3.5 | 0 | -28.094 | **no** | 20.8 | dispatcher |
| 16 | 1 | 4 | rr | 50 | 26,458 | 41.73 | 15,869 | 3.5 | 0 | -2.241 | **no** | 45.0 | data-mem arbiter |
| 16 | 1 | 4 | rr | 40 | 25,448 | 40.14 | 15,869 | 3.5 | 0 | 0.772 | yes | 41.3 | data-mem arbiter |
| 32 | 1 | 4 | rr | 50 | 53,133 | 83.81 | 31,201 | 3.5 | 0 | -13.595 | **no** | 29.8 | data-mem arbiter |
| 32 | 1 | 4 | rr | 25 | 51,851 | 81.78 | 31,202 | 3.5 | 0 | 0.604 | yes | 25.4 | data-mem arbiter |
| 2 | 2 | 4 | rr | 50 | 3,300 | 5.21 | 2,503 | 4.0 | 0 | 1.269 | yes | 53.4 | ALU divider |
| 4 | 4 | 4 | rr | 50 | 6,463 | 10.19 | 4,458 | 5.0 | 0 | 1.226 | yes | 53.3 | ALU divider |
| 8 | 8 | 4 | rr | 50 | 13,709 | 21.62 | 8,344 | 7.0 | 0 | 0.531 | yes | 51.4 | data-mem arbiter |
| 16 | 16 | 4 | rr | 50 | 49,938 | 78.77 | 21,075 | 3.0 | 0 | -2.814 | **no** | 43.8 | data-mem arbiter |
| 16 | 16 | 4 | rr | 40 | 49,005 | 77.29 | 21,075 | 3.0 | 0 | 0.165 | yes | 40.3 | prog-mem arbiter |
| 8 | 8 | 8 | rr | 50 | 18,253 | 28.79 | 8,501 | 9.0 | 0 | -0.998 | **no** | 47.6 | data-mem arbiter |
| 8 | 8 | 8 | rr | 40 | 17,654 | 27.85 | 8,501 | 9.0 | 0 | 0.492 | yes | 40.8 | data-mem arbiter |

| Cores | Prog ports | Data ports | Dispatcher | Clock (MHz) | Timing met | vecadd cycles (speedup) | matmul cycles (speedup) | compute cycles (speedup) | All results correct | Board = sim |
|---|---|---|---|---|---|---|---|---|---|---|
| 1 | 1 | 4 | stock | 50 | yes | 4,035 (1.0x) | 20,131 (1.0x) | 31,395 (1.0x) | yes | yes |
| 2 | 1 | 4 | stock | 50 | yes | 2,073 (1.95x) | 10,209 (1.97x) | 15,721 (2.0x) | yes | yes |
| 4 | 1 | 4 | stock | 50 | yes | 1,508 (2.68x) | 8,364 (2.41x) | 14,284 (2.2x) | yes | yes |
| 8 | 1 | 4 | stock | 50 | yes | 1,473 (2.74x) | 8,491 (2.37x) | 14,181 (2.21x) | yes | yes |
| 16 | 1 | 4 | stock | 50 | **no** | timeout | timeout | timeout | **no** | **no** |
| 16 | 1 | 4 | rr | 50 | **no** | 1,479 (2.73x) | 8,537 (2.36x) | 14,196 (2.21x) | yes | yes |
| 16 | 1 | 4 | rr | 40 | yes | 1,479 (2.73x) | 8,537 (2.36x) | 14,196 (2.21x) | yes | yes |
| 32 | 1 | 4 | rr | 50 | **no** | 1,495 (2.7x) | 8,537 (2.36x) | 14,192 (2.21x) | yes | yes |
| 32 | 1 | 4 | rr | 25 | yes | 1,495 (2.7x) | 8,537 (2.36x) | 14,192 (2.21x) | yes | yes |
| 2 | 2 | 4 | rr | 50 | yes | 2,026 (1.99x) | 10,074 (2.0x) | 15,706 (2.0x) | yes | yes |
| 4 | 4 | 4 | rr | 50 | yes | 1,032 (3.91x) | 5,056 (3.98x) | 7,872 (3.99x) | yes | yes |
| 8 | 8 | 4 | rr | 50 | yes | 801 (5.04x) | 2,648 (7.6x) | 3,976 (7.9x) | yes | yes |
| 16 | 16 | 4 | rr | 50 | **no** | 769 (5.25x) | 2,512 (8.01x) | 2,070 (15.17x) | yes | yes |
| 16 | 16 | 4 | rr | 40 | yes | 769 (5.25x) | 2,512 (8.01x) | 2,070 (15.17x) | yes | yes |
| 8 | 8 | 8 | rr | 50 | **no** | 548 (7.36x) | 2,550 (7.89x) | 3,961 (7.93x) | yes | yes |
| 8 | 8 | 8 | rr | 40 | yes | 548 (7.36x) | 2,550 (7.89x) | 3,961 (7.93x) | yes | yes |
