# Smooth Driving Coach — BeamNG.drive Mod

Mod de **BeamNG.drive (v0.39+)** projetado para treinar **direção suave para a vida real** com volante, pedais (acelerador, freio, embreagem) e câmbio manual (H-shifter).

Ele monitora a **Força G horizontal compensada pela inclinação da via (Pitch & Roll)** e o **Tranco / Solavanco (Jerk linear + cabeçada de suspensão)**, exibindo uma HUD minimalista no estilo nativo (vanilla) do BeamNG com nota de suavidade, gráfico em tempo real, alertas sonoros sutis e diagnóstico escrito da causa de cada tranco.

---

## Funcionalidades Principais

- **Radar "Copo d'Água" (Bola G + Horizonte de Inclinação + Anel de Tranco)**:
  - Círculo interno de conforto (`0.25g`) e escala de `0.50g` inspirados no `gForcesDebug` nativo.
  - Linha de horizonte indicando o `PITCH` (subida/descida) e `ROLL` (inclinação lateral) em tempo real.
  - Anel de ondulação ("água") que expande quando há pico de **Jerk** (solavanco).
- **Compensação Real de Subidas e Descidas (Pitch & Roll)**:
  - Separa a inclinação estática da via ($\theta_{\text{via}}, \phi_{\text{via}}$) do mergulho/cabeçada dinâmica da suspensão ($\Delta\theta_{\text{susp}}, \alpha_{\text{pitch}}$).
  - Subir ou descer uma ladeira em velocidade constante marca **`0.00g`**, sem penalizar a nota por causa da gravidade na rampa.
- **Gráfico Contínuo em Tempo Real (`SmoothieChart`)**:
  - Plota simultaneamente a **Força G Horizontal** (`#A8DD73`) e o **Tranco / Jerk** (`#FF6600`, em $\text{G/s}$).
- **Diagnóstico Inteligente da Causa do Tranco**:
  - **Embreagem solta rápido demais**: detecta soltura abrupta do pedal de embreagem na zona de acoplamento.
  - **Troca de marcha / Redução sem sincronizar giro (Rev-Match)**: identifica trancos logo após mudar de marcha.
  - **Cabeçada na parada (Freio)**: detecta quando você para o carro mantendo pressão alta no freio até o último instante em vez de aliviar o pé nos centímetros finais.
  - **Recuo na ladeira**: alerta imediatamente se o carro voltar para trás ao arrancar numa subida ($\ge 3^\circ$) e elogia arrancadas limpas na ladeira.
  - **Motor morreu (Stall)** e **Marcha arranhou (Gear Grind)**.
  - **Movimento brusco de volante** ou **pisada abrupta no acelerador/freio**.
- **Alertas Sonoros Sutis (Web Audio API)**:
  - Bipes suaves quando ocorre um tranco (para você manter os olhos na pista), com botão de **Mudo (`🔇`/`🔊`)** e **Reset da Nota (`↺`)** direto na HUD.

---

## Estrutura do Projeto

```text
├── lua/
│   └── vehicle/
│       └── extensions/
│           └── auto/
│               └── smoothDrivingCoach.lua      # Extensão física (Vehicle Lua VM)
├── ui/
│   └── modules/
│       └── apps/
│           └── SmoothDrivingCoach/
│               ├── app.json                    # Manifesto do UI App no BeamNG
│               ├── app.js                      # Diretiva AngularJS + Radar Canvas + SmoothieChart + Áudio
│               ├── app.css                     # Estilo minimalista Vanilla BeamNG
│               └── app.png                     # Ícone no menu de UI Apps
└── tests/
    └── test_smooth_driving_coach.lua           # Suíte de testes automatizados do modelo físico
```

---

## Como Instalar e Usar no BeamNG.drive

1. Copie as pastas `lua` e `ui` para dentro de:
   ```text
   %LOCALAPPDATA%\BeamNG\BeamNG.drive\current\mods\unpacked\smooth_driving_coach\
   ```
2. Abra o **BeamNG.drive** e carregue qualquer veículo em qualquer mapa (ex.: *West Coast USA*).
3. Abra o menu lateral -> **UI Apps** -> **Adicionar App** -> procure por **Smooth Driving Coach** (categoria *Dashboard*).
4. Posicione o painel na tela e pratique:
   - **Arrancadas suaves**: segure ~1s no ponto da embreagem antes de soltar tudo.
   - **Paradas sem cabeçada**: alivie a pressão do freio nos últimos centímetros antes do carro parar totalmente.
   - **Ladeiras**: ache o ponto de contato da embreagem antes de soltar o freio para não deixar o carro recuar.
