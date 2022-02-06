package types_test

import (
	"math/rand"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/smartcontractkit/chainlink/core/chains/evm/types"
	"github.com/smartcontractkit/chainlink/core/internal/cltest"
	"github.com/smartcontractkit/chainlink/core/internal/testutils/evmtest"
	"github.com/smartcontractkit/chainlink/core/internal/testutils/pgtest"
	"github.com/smartcontractkit/chainlink/core/utils"
)

func Test_PersistsReadsChain(t *testing.T) {
	db := pgtest.NewSqlxDB(t)

	val := utils.NewBigI(rand.Int63())
	addr := cltest.NewAddress()
	ks := make(map[string]types.ChainCfg)
	ks[addr.Hex()] = types.ChainCfg{EvmMaxGasPriceWei: val}
	chain := types.Chain{
		ID: *utils.NewBigI(rand.Int63()),
		Cfg: types.ChainCfg{
			KeySpecific: ks,
		},
	}

	evmtest.MustInsertChain(t, db, &chain)

	var loadedChain types.Chain
	require.NoError(t, db.Get(&loadedChain, "SELECT * FROM evm_chains WHERE id = $1", chain.ID))

	loadedVal := loadedChain.Cfg.KeySpecific[addr.Hex()].EvmMaxGasPriceWei
	assert.Equal(t, loadedVal, val)
}