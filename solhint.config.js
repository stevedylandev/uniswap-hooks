const customRules = require('solhint-plugin-openzeppelin');

// @dev Solhint rules to be applied
const rules = {
    'avoid-tx-origin': 'error',
    'const-name-snakecase': 'error',
    'contract-name-capwords': 'error',
    'event-name-capwords': 'error',
    'max-states-count': 'error',
    'explicit-types': 'error',
    'func-name-mixedcase': 'error',
    'func-param-name-mixedcase': 'error',
    'imports-on-top': 'error',
    'modifier-name-mixedcase': 'error',
    'no-console': 'error', 
    'no-global-import': 'error',
    'no-unused-vars': 'warn',
    'quotes': 'error',
    'use-forbidden-name': 'error',
    'var-name-mixedcase': 'error',
    'visibility-modifier-order': 'error',
    'interface-starts-with-i': 'error',
    'duplicated-imports': 'error',
    'no-unused-import': 'error',
    'state-visibility': 'error', 
    'func-visibility': ['error', { "ignoreConstructors": true }],
    'named-parameters-mapping': 'error',
    'gas-custom-errors': 'error', 
    'gas-calldata-parameters': 'warn', 
    'gas-struct-packing': 'warn',
}

module.exports = {
    plugins: ['openzeppelin'],
    rules: { 
      ...Object.fromEntries(customRules.map(r => [`openzeppelin/${r.ruleId}`, 'error'])),
      ...rules,
    },
  };