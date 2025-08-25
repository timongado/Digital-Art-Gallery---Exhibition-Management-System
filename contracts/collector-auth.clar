;; Collector Authentication Contract
;; Manages collector verification, authentication, and collection tracking

;; Constants
(define-constant CONTRACT-OWNER tx-sender)
(define-constant ERR-NOT-AUTHORIZED (err u400))
(define-constant ERR-COLLECTOR-EXISTS (err u401))
(define-constant ERR-COLLECTOR-NOT-FOUND (err u402))
(define-constant ERR-INVALID-INPUT (err u403))
(define-constant ERR-VERIFICATION-REQUIRED (err u404))
(define-constant ERR-INSUFFICIENT-REPUTATION (err u405))

;; Data Variables
(define-data-var next-collector-id uint u1)
(define-data-var verification-threshold uint u1000) ;; Minimum spend for auto-verification

;; Data Maps
(define-map collectors
  { collector-id: uint }
  {
    wallet: principal,
    name: (string-ascii 100),
    email-hash: (buff 32),
    verified: bool,
    reputation-score: uint,
    total-purchases: uint,
    total-spent: uint,
    preferred-categories: (list 10 (string-ascii 50)),
    created-at: uint
  }
)

(define-map collector-wallets
  { wallet: principal }
  { collector-id: uint }
)

(define-map collections
  { collector-id: uint }
  { artwork-ids: (list 100 uint) }
)

(define-map purchase-history
  { collector-id: uint, artwork-id: uint }
  {
    purchase-price: uint,
    purchase-date: uint,
    sale-id: uint,
    verified: bool
  }
)

(define-map collector-preferences
  { collector-id: uint }
  {
    max-price-range: uint,
    preferred-artists: (list 20 uint),
    notification-settings: uint,
    privacy-level: uint
  }
)

(define-map authentication-tokens
  { collector-id: uint }
  {
    token-hash: (buff 32),
    expires-at: uint,
    active: bool
  }
)

;; Private Functions
(define-private (is-contract-owner)
  (is-eq tx-sender CONTRACT-OWNER)
)

(define-private (is-collector-owner (collector-id uint))
  (match (map-get? collectors { collector-id: collector-id })
    collector-data (is-eq tx-sender (get wallet collector-data))
    false
  )
)

(define-private (calculate-reputation-score (total-purchases uint) (total-spent uint))
  (+ (* total-purchases u10) (/ total-spent u1000000)) ;; 10 points per purchase + 1 point per STX spent
)

;; Public Functions

;; Register new collector
(define-public (register-collector (name (string-ascii 100)) (email-hash (buff 32)) (preferred-categories (list 10 (string-ascii 50))))
  (let
    (
      (collector-id (var-get next-collector-id))
      (existing-collector (map-get? collector-wallets { wallet: tx-sender }))
    )
    (asserts! (is-none existing-collector) ERR-COLLECTOR-EXISTS)
    (asserts! (> (len name) u0) ERR-INVALID-INPUT)

    (map-set collectors
      { collector-id: collector-id }
      {
        wallet: tx-sender,
        name: name,
        email-hash: email-hash,
        verified: false,
        reputation-score: u0,
        total-purchases: u0,
        total-spent: u0,
        preferred-categories: preferred-categories,
        created-at: block-height
      }
    )

    (map-set collector-wallets
      { wallet: tx-sender }
      { collector-id: collector-id }
    )

    ;; Initialize empty collection
    (map-set collections
      { collector-id: collector-id }
      { artwork-ids: (list) }
    )

    (var-set next-collector-id (+ collector-id u1))
    (ok collector-id)
  )
)

;; Verify collector (admin or auto-verification)
(define-public (verify-collector (collector-id uint))
  (let
    (
      (collector-data (unwrap! (map-get? collectors { collector-id: collector-id }) ERR-COLLECTOR-NOT-FOUND))
    )
    (asserts! (or (is-contract-owner) (>= (get total-spent collector-data) (var-get verification-threshold))) ERR-NOT-AUTHORIZED)

    (map-set collectors
      { collector-id: collector-id }
      (merge collector-data { verified: true, reputation-score: (+ (get reputation-score collector-data) u100) })
    )
    (ok true)
  )
)

;; Record artwork purchase
(define-public (record-purchase (artwork-id uint) (purchase-price uint) (sale-id uint))
  (let
    (
      (collector-wallet-data (unwrap! (map-get? collector-wallets { wallet: tx-sender }) ERR-COLLECTOR-NOT-FOUND))
      (collector-id (get collector-id collector-wallet-data))
      (collector-data (unwrap! (map-get? collectors { collector-id: collector-id }) ERR-COLLECTOR-NOT-FOUND))
      (current-collection (default-to { artwork-ids: (list) } (map-get? collections { collector-id: collector-id })))
      (new-total-purchases (+ (get total-purchases collector-data) u1))
      (new-total-spent (+ (get total-spent collector-data) purchase-price))
      (new-reputation (calculate-reputation-score new-total-purchases new-total-spent))
    )
    (asserts! (> purchase-price u0) ERR-INVALID-INPUT)

    ;; Record purchase
    (map-set purchase-history
      { collector-id: collector-id, artwork-id: artwork-id }
      {
        purchase-price: purchase-price,
        purchase-date: block-height,
        sale-id: sale-id,
        verified: false
      }
    )

    ;; Add to collection
    (map-set collections
      { collector-id: collector-id }
      { artwork-ids: (unwrap! (as-max-len? (append (get artwork-ids current-collection) artwork-id) u100) ERR-INVALID-INPUT) }
    )

    ;; Update collector stats
    (map-set collectors
      { collector-id: collector-id }
      (merge collector-data {
        total-purchases: new-total-purchases,
        total-spent: new-total-spent,
        reputation-score: new-reputation
      })
    )

    ;; Auto-verify if threshold met
    (if (and (not (get verified collector-data)) (>= new-total-spent (var-get verification-threshold)))
      (map-set collectors
        { collector-id: collector-id }
        (merge collector-data {
          verified: true,
          total-purchases: new-total-purchases,
          total-spent: new-total-spent,
          reputation-score: (+ new-reputation u100)
        })
      )
      false
    )

    (ok true)
  )
)

;; Update collector preferences
(define-public (update-preferences (max-price-range uint) (preferred-artists (list 20 uint)) (notification-settings uint) (privacy-level uint))
  (let
    (
      (collector-wallet-data (unwrap! (map-get? collector-wallets { wallet: tx-sender }) ERR-COLLECTOR-NOT-FOUND))
      (collector-id (get collector-id collector-wallet-data))
    )
    ;; replaced &lt;= with native Clarity <= operator
    (asserts! (<= privacy-level u3) ERR-INVALID-INPUT) ;; 0=public, 1=limited, 2=private, 3=anonymous

    (map-set collector-preferences
      { collector-id: collector-id }
      {
        max-price-range: max-price-range,
        preferred-artists: preferred-artists,
        notification-settings: notification-settings,
        privacy-level: privacy-level
      }
    )
    (ok true)
  )
)

;; Generate authentication token
(define-public (generate-auth-token (token-hash (buff 32)) (duration-blocks uint))
  (let
    (
      (collector-wallet-data (unwrap! (map-get? collector-wallets { wallet: tx-sender }) ERR-COLLECTOR-NOT-FOUND))
      (collector-id (get collector-id collector-wallet-data))
      (collector-data (unwrap! (map-get? collectors { collector-id: collector-id }) ERR-COLLECTOR-NOT-FOUND))
    )
    (asserts! (get verified collector-data) ERR-VERIFICATION-REQUIRED)
    (asserts! (> duration-blocks u0) ERR-INVALID-INPUT)
    ;; replaced &lt;= with native Clarity <= operator
    (asserts! (<= duration-blocks u1440) ERR-INVALID-INPUT) ;; Max 1440 blocks (~1 day)

    (map-set authentication-tokens
      { collector-id: collector-id }
      {
        token-hash: token-hash,
        expires-at: (+ block-height duration-blocks),
        active: true
      }
    )
    (ok true)
  )
)

;; Validate authentication token
(define-public (validate-auth-token (collector-id uint) (token-hash (buff 32)))
  (let
    (
      (token-data (unwrap! (map-get? authentication-tokens { collector-id: collector-id }) ERR-NOT-AUTHORIZED))
    )
    (asserts! (get active token-data) ERR-NOT-AUTHORIZED)
    (asserts! (> (get expires-at token-data) block-height) ERR-NOT-AUTHORIZED)
    (asserts! (is-eq (get token-hash token-data) token-hash) ERR-NOT-AUTHORIZED)

    (ok true)
  )
)

;; Read-only functions

(define-read-only (get-collector (collector-id uint))
  (map-get? collectors { collector-id: collector-id })
)

(define-read-only (get-collector-by-wallet (wallet principal))
  (match (map-get? collector-wallets { wallet: wallet })
    wallet-data (map-get? collectors { collector-id: (get collector-id wallet-data) })
    none
  )
)

(define-read-only (get-collector-collection (collector-id uint))
  (map-get? collections { collector-id: collector-id })
)

(define-read-only (get-purchase-history (collector-id uint) (artwork-id uint))
  (map-get? purchase-history { collector-id: collector-id, artwork-id: artwork-id })
)

(define-read-only (get-collector-preferences (collector-id uint))
  (map-get? collector-preferences { collector-id: collector-id })
)

(define-read-only (get-auth-token (collector-id uint))
  (map-get? authentication-tokens { collector-id: collector-id })
)

(define-read-only (get-next-collector-id)
  (var-get next-collector-id)
)

(define-read-only (is-collector-verified (collector-id uint))
  (match (map-get? collectors { collector-id: collector-id })
    collector-data (get verified collector-data)
    false
  )
)
