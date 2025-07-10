const customRules = require('solhint-plugin-openzeppelin');
const { baseRules } = require('./solhint.base.config');

/// @dev Rules applied to `src/` files only.
const srcOnlyRules = {
  // 'ordering', large changes to be condensed in a single PR.
  'func-name-mixedcase': 'error', // breaks foundry testing patterns
  // rules innecesary in tests:
  'state-visibility': 'error', 
  'gas-custom-errors': 'error', 
  'gas-calldata-parameters': 'error', 
  'gas-struct-packing': 'error',
}

module.exports = {
  plugins: ['openzeppelin'],
  rules: { 
    ...Object.fromEntries(customRules.map(r => [`openzeppelin/${r.ruleId}`, 'error'])),
    ...baseRules,
    ...srcOnlyRules,
  },
};
