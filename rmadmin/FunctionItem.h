#ifndef FUNCTIONITEM_H_190509
#define FUNCTIONITEM_H_190509
#include <optional>
#include <vector>
#include "OperationsItem.h"

class GraphViewSettings;

class FunctionItem : public OperationsItem
{
public:
  std::optional<bool> isUsed;
  // FIXME: Function destructor must clean those:
  std::vector<FunctionItem const*> parents;
  FunctionItem(OperationsItem *treeParent, QString const &name, GraphViewSettings const *);
  ~FunctionItem();
  QVariant data(int) const;
  QRectF boundingRect() const;
};

std::ostream &operator<<(std::ostream &, FunctionItem const &);

#endif
