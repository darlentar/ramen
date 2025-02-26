#ifndef CHART_H_190527
#define CHART_H_190527
/* A Chart is a graphical representation of some column of a given table
 * (to plot columns from different tables into the same chart one has to
 * join those tables into a single one in a dedicated new ramen function).
 *
 * It has a Graphic (graphical representation such as a plot or a pie) that
 * is chosen according to the selected columns but that choice can be manually
 * overridden.
 *
 * A chart has a set of controls to pick time range, colors... (specific
 * graphics may have additional controls) */
#include <functional>
#include <memory>
#include <vector>
#include <QWidget>

class QVBoxLayout;
class Graphic;
class PastData;
struct RamenValue;
class TailModel;
class TimeRangeEdit;

class Chart : public QWidget
{
  Q_OBJECT

  std::shared_ptr<TailModel const> tailModel;
  std::shared_ptr<PastData> pastData;
  std::vector<int> columns;

  QVBoxLayout *layout;
  Graphic *graphic;

  Graphic *defaultGraphic();

  /* Controls: */

  TimeRangeEdit *timeRangeEdit;

public:
  Chart(std::shared_ptr<TailModel const>,
        std::shared_ptr<PastData>,
        std::vector<int> columns,
        QWidget *parent = nullptr);

  /* Iterate over the points of all datasets (within time range): */
  void iterValues(std::function<void (std::vector<RamenValue const *> const)> cb) const;

  QString const labelName(int idx) const;

  int numColumns() const { return columns.size(); }

public slots:
  // Update the graphic after adding/removing a dataset:
  void updateGraphic();

  // Update the chosen graphic when controls have changed or points were added:
  void updateChart();
};

#endif
