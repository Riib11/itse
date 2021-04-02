module Language.Itse.Checking where

import Control.Applicative
import Control.Monad.Except
import Control.Monad.State
import Language.Itse.Grammar
import Text.Printf

{-
## Control Flow
-}

type M = Except E

type E = String

{-
## Contexts
-}

data Context
  = Context_Empty
  | Context_Typing (Name Term) Type Context
  | Context_Kinding (Name Type) Kind Context
  | Context_Closure Closure Context

{-
## Closures
-}

-- laws:
-- - no (mutually) recursive mappings
-- - terms are bound to closed terms
-- - types are bound to types closed in domain(closure)
data Closure = Closure
  { bindingsTm :: [(Name Term, (Term, Type))],
    bindingsTy :: [(Name Type, (Type, Kind))],
    bindingsKd :: [(Name Kind, Kind)]
  }

type family LookupResult a where
  LookupResult Term = (Term, Type)
  LookupResult Type = (Type, Kind)
  LookupResult Kind = Kind

lookupClosure :: Name a -> Closure -> Maybe (LookupResult a)
lookupClosure = \case
  x@(NameTm _) -> \Closure {bindingsTm} -> Prelude.lookup x bindingsTm
  x@(NameTy _) -> \Closure {bindingsTy} -> Prelude.lookup x bindingsTy
  x@(NameKd _) -> \Closure {bindingsKd} -> Prelude.lookup x bindingsKd

lookupContext :: Name a -> Context -> Maybe (LookupResult a)
lookupContext x = \case
  Context_Empty -> Nothing
  Context_Typing _ _ ctx -> lookupContext x ctx
  Context_Kinding _ _ ctx -> lookupContext x ctx
  Context_Closure clo ctx -> lookupClosure x clo <|> lookupContext x ctx

{-
## Processing
-}

processPrgm :: Prgm -> StateT Context M ()
processPrgm (Prgm stmts) = mapM_ processStmt stmts

processStmt :: Stmt -> StateT Context M ()
processStmt = \case
  Stmt_DefnTm x t a -> do
    declareNameTy x t
    t' <- lift . synthesizeType a =<< get
    lift $ unify (Type t) (Type t')
  Stmt_DefnTy x k t -> do
    declareNameKd x k
    k' <- lift . synthesizeKind t =<< get
    lift $ unify (Kind k) (Kind k')

declareNameTy :: Name Term -> Type -> StateT Context M ()
declareNameTy x t = modify $ Context_Typing x t

declareNameKd :: Name Type -> Kind -> StateT Context M ()
declareNameKd x k = modify $ Context_Kinding x k

{-
## Free Names
-}

freeNameTms :: Expr a -> [Name Term]
freeNameTms (Term _a) = case _a of
  Term_Ref x -> [x]
  Term_AbsTm x t a -> (freeNameTms (Type t) ++ freeNameTms (Term a)) `withoutName` x
  Term_AppTm a b -> freeNameTms (Term a) ++ freeNameTms (Term b)
  Term_AbsTy _ k a -> freeNameTms (Kind k) ++ freeNameTms (Term a)
  Term_AppTy a t -> freeNameTms (Term a) ++ freeNameTms (Type t)
freeNameTms (Type _t) = case _t of
  Type_Ref _ -> []
  Type_AppTm t a -> freeNameTms (Type t) ++ freeNameTms (Term a)
  Type_AbsTy _ k t -> freeNameTms (Kind k) ++ freeNameTms (Type t)
  Type_AbsTm x s t -> (freeNameTms (Type s) ++ freeNameTms (Type t)) `withoutName` x
  Type_AppTy s t -> freeNameTms (Type s) ++ freeNameTms (Type t)
  Type_Iota x t -> freeNameTms (Type t) `withoutName` x
freeNameTms (Kind _k) = case _k of
  Kind_Unit -> []
  Kind_AbsTm x t k -> (freeNameTms (Type t) ++ freeNameTms (Kind k)) `withoutName` x
  Kind_AbsTy _ k l -> freeNameTms (Kind k) ++ freeNameTms (Kind l)

freeNameTys :: Expr a -> [Name Type]
freeNameTys (Term _a) = case _a of
  Term_Ref _ -> []
  Term_AbsTm _ t a -> freeNameTys (Type t) ++ freeNameTys (Term a)
  Term_AppTm a b -> freeNameTys (Term a) ++ freeNameTys (Term b)
  Term_AbsTy x k a -> (freeNameTys (Kind k) ++ freeNameTys (Term a)) `withoutName` x
  Term_AppTy a t -> freeNameTys (Term a) ++ freeNameTys (Type t)
freeNameTys (Type _t) = case _t of
  Type_Ref x -> [x]
  Type_Iota _ t -> freeNameTys (Type t)
  Type_AppTm t a -> freeNameTys (Type t) ++ freeNameTys (Term a)
  Type_AbsTy x k t -> (freeNameTys (Kind k) ++ freeNameTys (Type t)) `withoutName` x
  Type_AbsTm _ s t -> freeNameTys (Type s) ++ freeNameTys (Type t)
  Type_AppTy s t -> freeNameTys (Type s) ++ freeNameTys (Type t)
freeNameTys (Kind _k) = case _k of
  Kind_Unit -> []
  Kind_AbsTm _ t k -> freeNameTys (Type t) ++ freeNameTys (Kind k)
  Kind_AbsTy x k l -> (freeNameTys (Kind k) ++ freeNameTys (Kind l)) `withoutName` x

withoutName :: [Name a] -> Name a -> [Name a]
withoutName xs x = filter (x /=) xs

{-
## Wellformed-ness
-}

wellformedContext :: Context -> M ()
wellformedContext _ctx = case _ctx of
  Context_Empty ->
    return ()
  Context_Typing _ t ctx -> do
    wellformedContext ctx
    checkKind t Kind_Unit ctx
  Context_Kinding _ k ctx -> do
    wellformedContext ctx
    wellformedKind k ctx
  Context_Closure clo ctx ->
    wellformedClosure clo ctx

wellformedClosure :: Closure -> Context -> M ()
wellformedClosure clo ctx = do
  mapM_ (\(_, (a, t)) -> checkType a t (Context_Closure clo ctx)) $ bindingsTm clo
  mapM_ (\(_, (t, k)) -> checkKind t k (Context_Closure clo ctx)) $ bindingsTy clo
  mapM_ (flip wellformedKind ctx . snd) $ bindingsKd clo

wellformedKind :: Kind -> Context -> M ()
wellformedKind _k ctx = case _k of
  Kind_Unit ->
    return ()
  Kind_AbsTy x k l -> do
    wellformedKind l (Context_Kinding x k ctx)
    wellformedKind k ctx
  Kind_AbsTm x t k -> do
    wellformedKind k (Context_Typing x t ctx)
    checkKind t Kind_Unit ctx

{-
## Kinding
-}

checkKind :: Type -> Kind -> Context -> M ()
checkKind t k ctx = do
  wellformedKind k ctx -- is this needed?
  k' <- synthesizeKind t ctx
  unify (Kind k) (Kind k')

synthesizeKind :: Type -> Context -> M Kind
synthesizeKind _t ctx = case _t of
  -- x
  Type_Ref x ->
    -- ctx |- x : k in ctx
    synthesizeKind_NameTy x ctx
  -- s a
  Type_AppTm s a -> do
    -- ctx |- s :: Π x : t . k
    (x, _, k) <-
      synthesizeKind s ctx >>= \case
        Kind_AbsTm x t k -> return (x, t, k)
        k -> throwError $ printf "invalid type-term applicant: `%s :: %s`" (show s) (show k)
    -- ctx |- a :: s
    checkType a s ctx
    -- ctx |- s a :: [x => a] k
    return . fromExpr $ substitute x (Term a) (Kind k)
  -- λ x : k . t
  Type_AbsTy x k t -> do
    -- ctx, x :: k |- t :: l
    l <- synthesizeKind t (Context_Kinding x k ctx)
    -- ctx |- k WF
    wellformedKind k ctx
    -- ctx |- forall x : k . t :: Π x : k . l
    return $ Kind_AbsTy x k l
  -- λ x : s . t
  Type_AbsTm x s t -> do
    -- ctx, x :: s |- t :: k
    k <- synthesizeKind t (Context_Typing x s ctx)
    -- ctx |- t :: *
    checkKind t Kind_Unit ctx
    -- ctx |- λ x : s . t :: Π x : s . k
    return $ Kind_AbsTm x s k
  -- s t
  Type_AppTy s t -> do
    -- ctx |- s :: Π x : k . l
    (x, k, l) <-
      synthesizeKind s ctx >>= \case
        Kind_AbsTy x k l -> return (x, k, l)
        k -> throwError $ printf "invalid type-type applicant: `%s :: %s`" (show s) (show k)
    -- ctx |- t :: k
    checkKind t k ctx
    -- ctx |- s t :: [x => t] l
    return . fromExpr $ substitute x (Type t) (Kind l)
  -- ι x . t
  Type_Iota x t -> do
    -- ctx, x :: ι x . t |- t :: *
    checkKind t Kind_Unit (Context_Typing x (Type_Iota x t) ctx)
    -- ctx |- ι x . t :: *
    return Kind_Unit

{-
## Typing
-}

checkType :: Term -> Type -> Context -> M ()
checkType a _t ctx = case _t of
  -- SelfGen
  -- ι x . t
  Type_Iota x t -> do
    -- ctx |- a :: [x => a] t
    checkType a (fromExpr $ substitute x (Term a) (Type t)) ctx
    -- ctx |- ι x . t :: *
    checkKind (Type_Iota x t) Kind_Unit ctx
  t ->
    synthesizeType a ctx >>= \case
      -- SelfInst
      -- TODO: potential problem -- what if doesn't want to SelfInst yet?
      -- ctx |- a :: ι x . t'
      Type_Iota x t' ->
        -- ctx |- [x => a] t ~ t'
        unify (substitute x (Term a) (Type t)) (Type t')
      t' ->
        unify (Type t) (Type t')

synthesizeType :: Term -> Context -> M Type
synthesizeType _a ctx = case _a of
  -- x
  Term_Ref x ->
    synthesizeType_NameTm x ctx
  -- λ x : s . a
  Term_AbsTm x s a -> do
    -- ctx |- s :: *
    checkKind s Kind_Unit ctx
    -- ctx, x :: a |- a :: t
    t <- synthesizeType a (Context_Typing x s ctx)
    -- ctx |- λ x : s . a :: λ x : s . t
    return $ Type_AbsTm x s t
  -- a b
  Term_AppTm a b -> do
    -- ctx |- a :: λ x : s . t
    (x, s, t) <-
      synthesizeType a ctx >>= \case
        Type_AbsTm x s t -> return (x, s, t)
        t -> throwError $ printf "invalid term-term applicant: `%s :: %s`" (show a) (show t)
    -- ctx |- b :: s
    checkType b s ctx
    -- ctx |- a b ::
    return . fromExpr $ substitute x (Term b) (Type t)
  -- λ x : k . a
  Term_AbsTy x k a -> do
    -- ctx |- k WF
    wellformedKind k ctx
    -- ctx, x :: k |- a :: t
    t <- synthesizeType a (Context_Kinding x k ctx)
    -- ctx |- λ x : k . a :: λ x : k . t
    return $ Type_AbsTy x k t
  -- a s
  Term_AppTy a s -> do
    -- ctx |- a :: λ x : k . t
    (x, k, t) <-
      synthesizeType a ctx >>= \case
        Type_AbsTy x k t -> return (x, k, t)
        t -> throwError $ printf "invalid term-type applicant: `%s :: %s`" (show a) (show t)
    -- ctx |- s :: k
    checkKind s k ctx
    -- ctx |- a t :: [x => s] t
    return . fromExpr $ substitute x (Type s) (Type t)

{-
## Names
-}

synthesizeType_NameTm :: Name Term -> Context -> M Type
synthesizeType_NameTm x Context_Empty =
  throwError $ printf "undeclared term name: `%s`" (show x)
synthesizeType_NameTm x (Context_Typing y t ctx) =
  if x == y
    then return t
    else synthesizeType_NameTm x ctx
synthesizeType_NameTm x (Context_Kinding _ _ ctx) =
  synthesizeType_NameTm x ctx
synthesizeType_NameTm x (Context_Closure clo ctx) =
  case lookupClosure x clo of
    Just (_, t) -> return t
    Nothing -> synthesizeType_NameTm x ctx

synthesizeKind_NameTy :: Name Type -> Context -> M Kind
synthesizeKind_NameTy x Context_Empty =
  throwError $ printf "undeclared type name: `%s`" (show x)
synthesizeKind_NameTy x (Context_Typing _ _ ctx) =
  synthesizeKind_NameTy x ctx
synthesizeKind_NameTy x (Context_Kinding y k ctx) =
  if x == y
    then return k
    else synthesizeKind_NameTy x ctx
synthesizeKind_NameTy x (Context_Closure clo ctx) =
  case lookupClosure x clo of
    Just (_, k) -> return k
    Nothing -> synthesizeKind_NameTy x ctx

{-
## Unification
-}

-- congruence closure of beta-reduction
unify :: Expr a -> Expr a -> M ()
unify e1 e2 =
  runExceptT (go e1 e2) >>= \case
    Left (s1, s2) -> throwError $ printf "cannot unify subexpression `%s` with `%s`, in order to unify expression `%s` with `%s`" (show s1) (show s2) (show e1) (show e2)
    Right () -> return ()
  where
    go :: Expr a -> Expr a -> ExceptT (String, String) M ()
    -- term
    go (Term _a1) (Term _a2) = case (_a1, _a2) of
      (Term_Ref x1, Term_Ref x2) ->
        if x1 /= x2
          then throwError (show _a1, show _a2)
          else return ()
      (Term_AbsTm x1 t1 a1, Term_AbsTm x2 t2 a2) -> do
        go (Type t1) $ substitute x2 (Term $ Term_Ref x1) (Type t2)
        go (Term a1) $ substitute x2 (Term $ Term_Ref x1) (Term a2)
      (Term_AppTm a1 b1, Term_AppTm a2 b2) -> do
        go (Term a1) (Term a2)
        go (Term b1) (Term b2)
      _ -> throwError $ (show _a1, show _a2)
    -- type
    go (Type _t1) (Type _t2) = case (_t1, _t2) of
      (Type_Ref x1, Type_Ref x2) ->
        if x1 /= x2
          then throwError $ (show _t1, show _t2)
          else return ()
      (Type_AppTm s1 a1, Type_AppTm s2 a2) -> do
        go (Type s1) (Type s2)
        go (Term a1) (Term a2)
      (Type_AbsTy x1 k1 t1, Type_AbsTy x2 k2 t2) -> do
        go (Kind k1) $ substitute x2 (Type $ Type_Ref x1) (Kind k2)
        go (Type t1) $ substitute x2 (Type $ Type_Ref x1) (Type t2)
      (Type_AbsTm x1 s1 t1, Type_AbsTm x2 s2 t2) -> do
        go (Type s1) $ substitute x2 (Term $ Term_Ref x1) (Type s2)
        go (Type t1) $ substitute x2 (Term $ Term_Ref x1) (Type t2)
      (Type_AppTy s1 t1, Type_AppTy s2 t2) -> do
        go (Type s1) (Type s2)
        go (Type t1) (Type t2)
      (Type_Iota x1 t1, Type_Iota x2 t2) ->
        go (Type t1) $ substitute x2 (Term $ Term_Ref x1) (Type t2)
      _ ->
        throwError (show _t1, show _t2)
    -- kind
    go (Kind _k1) (Kind _k2) = case (_k1, _k2) of
      (Kind_Unit, Kind_Unit) ->
        return ()
      (Kind_AbsTm x1 t1 k1, Kind_AbsTm x2 t2 k2) -> do
        go (Type t1) $ substitute x2 (Term $ Term_Ref x1) (Type t2)
        go (Kind k1) $ substitute x2 (Term $ Term_Ref x1) (Kind k2)
      (Kind_AbsTy x1 k1 l1, Kind_AbsTy x2 k2 l2) -> do
        go (Kind k1) $ substitute x2 (Type $ Type_Ref x1) (Kind k2)
        go (Kind l1) $ substitute x2 (Type $ Type_Ref x1) (Kind l2)
      _ ->
        throwError $ (show _k1, show _k2)

{-
## Reduction
-}

evaluate :: Expr a -> Context -> M (Expr a)
evaluate e ctx =
  reduce e ctx >>= \case
    Just e' -> evaluate e' ctx
    Nothing -> return e

reduce :: Expr a -> Context -> M (Maybe (Expr a))
--
reduce (Term _a) ctx = case _a of
  --
  Term_Ref x ->
    return $ Term . fst <$> lookupContext x ctx
  --
  Term_AbsTm _ _ _ ->
    return Nothing
  --
  Term_AppTm _a b -> do
    (x, a) <-
      evaluate (Term _a) ctx >>= \case
        Term (Term_AbsTm x _ a) -> return (x, a)
        a -> throwError $ printf "invalid term-term applicant: `%s`" (show a)
    return . Just $ substitute x (Term b) (Term a)
  --
  Term_AbsTy _ _ _ ->
    return Nothing
  --
  Term_AppTy _a t -> do
    (x, a) <-
      evaluate (Term _a) ctx >>= \case
        Term (Term_AbsTy x _ a) -> return (x, a)
        a -> throwError $ printf "invalid term-type applicant: `%s`" (show a)
    return . Just $ substitute x (Type t) (Term a)
--
reduce (Type _t) ctx = case _t of
  --
  Type_Ref x ->
    return $ Type . fst <$> lookupContext x ctx
  --
  Type_AbsTm _ _ _ ->
    return Nothing
  --
  Type_AppTm _t a -> do
    (x, t) <-
      evaluate (Type _t) ctx >>= \case
        Type (Type_AbsTm x _ t) -> return (x, t)
        t -> throwError $ printf "invalid type-term applicant: `%s`" (show t)
    return . Just $ substitute x (Term a) (Type t)
  --
  Type_AbsTy _ _ _ ->
    return Nothing
  --
  Type_AppTy _s t -> do
    (x, s) <-
      evaluate (Type _s) ctx >>= \case
        Type (Type_AbsTy x _ s) -> return (x, s)
        s -> throwError $ printf "invalid type-type applicant: `%s`" (show s)
    return . Just $ substitute x (Type t) (Type s)
  --
  Type_Iota _ _ -> do
    return Nothing
-- substitutes kind
reduce (Kind _k) _ =
  return Nothing

{-
## Substitution
-}

-- [x => a] b
substitute :: Name a -> Expr a -> Expr b -> Expr b
--
substitute x e (Term _a) = case _a of
  --
  Term_Ref y -> case x of
    NameTm _ ->
      if x == y
        then e
        else Term $ Term_Ref y
    _ -> Term $ Term_Ref y
  --
  Term_AbsTm y t a -> Term case x of
    NameTm _ ->
      if x == y
        then Term_AbsTm y t a
        else
          Term_AbsTm
            y
            (fromExpr $ substitute x e (Type t))
            (fromExpr $ substitute x e (Term a))
    _ ->
      Term_AbsTm
        y
        (fromExpr $ substitute x e (Type t))
        (fromExpr $ substitute x e (Term a))
  --
  Term_AppTm a b ->
    Term $
      Term_AppTm
        (fromExpr $ substitute x e (Term a))
        (fromExpr $ substitute x e (Term b))
  --
  Term_AbsTy y k a -> Term case x of
    NameTy _ ->
      if x == y
        then Term_AbsTy y k a
        else
          Term_AbsTy
            y
            (fromExpr $ substitute x e (Kind k))
            (fromExpr $ substitute x e (Term a))
    _ ->
      Term_AbsTy
        y
        (fromExpr $ substitute x e (Kind k))
        (fromExpr $ substitute x e (Term a))
  --
  Term_AppTy a t ->
    Term $
      Term_AppTy
        (fromExpr $ substitute x e (Term a))
        (fromExpr $ substitute x e (Type t))
--
substitute x e (Type _t) = case _t of
  Type_Ref y -> Type case x of
    NameTy _ ->
      if x == y
        then fromExpr e
        else Type_Ref y
    _ -> Type_Ref y
  Type_AbsTm y s t -> Type case x of
    NameTm _ ->
      if x == y
        then Type_AbsTm y s t
        else
          Type_AbsTm
            y
            (fromExpr $ substitute x e (Type s))
            (fromExpr $ substitute x e (Type t))
    _ ->
      Type_AbsTm
        y
        (fromExpr $ substitute x e (Type s))
        (fromExpr $ substitute x e (Type t))
  Type_AppTm t a ->
    Type $
      Type_AppTm
        (fromExpr $ substitute x e (Type t))
        (fromExpr $ substitute x e (Term a))
  Type_AbsTy y k t -> Type case x of
    NameTy _ ->
      if x == y
        then Type_AbsTy y k t
        else
          Type_AbsTy
            y
            (fromExpr $ substitute x e (Kind k))
            (fromExpr $ substitute x e (Type t))
    _ ->
      Type_AbsTy
        y
        (fromExpr $ substitute x e (Kind k))
        (fromExpr $ substitute x e (Type t))
  Type_AppTy s t ->
    Type $
      Type_AppTy
        (fromExpr $ substitute x e (Type s))
        (fromExpr $ substitute x e (Type t))
  Type_Iota y t -> Type case x of
    NameTm _ ->
      if x == y
        then Type_Iota y t
        else Type_Iota y (fromExpr $ substitute x e (Type t))
    _ -> Type_Iota y (fromExpr $ substitute x e (Type t))
substitute x e (Kind _k) = case _k of
  Kind_Unit ->
    Kind Kind_Unit
  Kind_AbsTm y t k -> Kind case x of
    NameTm _ ->
      if x == y
        then Kind_AbsTm y t k
        else
          Kind_AbsTm
            y
            (fromExpr $ substitute x e (Type t))
            (fromExpr $ substitute x e (Kind k))
    _ ->
      Kind_AbsTm
        y
        (fromExpr $ substitute x e (Type t))
        (fromExpr $ substitute x e (Kind k))
  Kind_AbsTy y k l -> Kind case x of
    NameTy _ ->
      if x == y
        then Kind_AbsTy y k l
        else
          Kind_AbsTy
            y
            (fromExpr $ substitute x e (Kind k))
            (fromExpr $ substitute x e (Kind l))
    _ ->
      Kind_AbsTy
        y
        (fromExpr $ substitute x e (Kind k))
        (fromExpr $ substitute x e (Kind l))
