const { baseRules } = require('./solhint.base.config');

/// @dev Rules applied to `test/` files only.
const testOnlyRules = {
 // 'foundry-test-functions': 'error',
}

module.exports = {
  plugins: ['openzeppelin'],
  rules: { 
    ...baseRules,
    ...testOnlyRules,
  },
};
