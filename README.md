これはweb3エスクローのためのスマートコントラクトの実験品である。

⚠️ 実験用／研究用プロトタイプ

本契約は専門的な監査を受けておらず、実際の資金での利用は避けてください。

デプロイ済み
[ETHERSCANのリンク](https://sepolia.etherscan.io/address/0x654d644d6cc1e1f74c0ce3ad9958487ef6446fdf)

## What for


# Web2の導線にweb3の回線を敷く


一般的なステーブルコイン決済は P2P の送金に寄りがちで、Web2 プラットフォームにとって不可避の業務である「調停」を欠いている。
調停とは、履行されたか、キャンセルするか、キャンセルするとして何割を返すか、を決める業務である。
その判断自体は Web2 に残す。チェーンがやるのは判断ではなく執行である。

本コントラクトは、支払者・受取者・調停者（プラットフォーム）のうち 2-of-3 の署名で、預かった ERC-20 を払い出すエスクローである。
Web2 は EIP-712 形式の提案（escrowId, Action, allocations）を作成する。実行条件は、その typed data に対する 2 者の署名である。
プラットフォームは提案を作れるが、2票目がなければ資金を動かせない。資金はコントラクトにロックされ、単独の管理者引き出しは持たない。

これにより、Web2 型の調停フローを残したまま、プラットフォームがカストディせずに決済できる。
日本のようにカストディ規制が厳しい環境でも、プラットフォーム型の Web3 決済を載せる余地がある。

## Diagram

```mermaid
sequenceDiagram
    autonumber
    actor P as Payer (旅行者)
    participant C as Escrow Contract (Sepolia)
    actor A as Arbitrator (Web2 OTA)
    actor R as Payee (宿泊施設)

    Note over P,R: Web2の導線に、Web3の回線を敷く

    %% 1. 予約・デポジット
    P->>C: JPYCをデポジット (Payer, Payee, Arbitrator登録)

    %% 2. 処理フロー（正常系・異常系）
    alt 正常系：チェックイン完了 (2-of-3 署名)
        P->>R: 現地チェックイン (相互確認)
        P->>C: Payer + Payee 署名送信
        C->>R: JPYCをPayeeへ直接送金 (仲裁人の介入なし)

    else 異常系A：キャンセル・返金 (2-of-3 署名)
        P->>A: Web2上でキャンセル申請
        A->>C: Payer + Arbitrator 署名送信
        C->>P: JPYCをPayerへ返金

    else 異常系B：ノーショー・不泊 (2-of-3 署名)
        R->>A: ノーショー申告・証明
        A->>C: Payee + Arbitrator 署名送信
        C->>R: JPYCをPayeeへ送金
    end

 ```

## Contract

```
enum Action {
        DONE,   // 正常完了（Payeeへの全額送金）
        REFUND, // 割合指定キャンセル（PayerとPayeeで分割）
        CANCEL  // 完全キャンセル（Payerへの全額返金）
    }
```
チェックインといった正規の取引成立の場合、DONEで支払者、受取者の2of3の署名で実行する。<br>
中途キャンセルの場合、REFUNDでアロケーションを設定し、支払者、調停者の2of3で返金処理を実行する<br>
受取者都合のキャンセルの場合、CANCELで受取者、調停者の2of3署名でキャンセルを実行する。<br>

```
function createEscrow(
        bytes32 escrowId,
        address payee,
        address relayer,
        address token,
        uint256 amount,
        uint256 deadline
    )
```

escrowIdを任意に作成し、payee、relayer(ここではArbitatorとも称する)を指定、<br>
支払うERC20トークンと数量を指定し、のちに説明するclaimAfterDeadlineのための締め切り時間（deadline UNIX時間）を設定する。<br>
この署名をpayerが行うことで、コントラクトに資金が預けられる。<br>

```
function signExecute(
        bytes32 escrowId,
        Action action,
        Allocation[] calldata allocations
    )
```
Actionの対応、並びにAllocationを返金率等は、web2のプラットフォームを通して作成し、2of3の署名を集めることができたらsignExecuteの通り実行とする。

提案は複数併存できる。実行されるのは 2 署名が先に揃った配分である。<br>
支払者が通常と異なる allocations を出しても、調停者＋受取者の配分が 2 票に達すれば、そちらが執行される。<br>


```
function claimAfterDeadline(bytes32 escrowId)
```
締め切りを過ぎたコントラクトは、これで受取者に全額送金とする。
